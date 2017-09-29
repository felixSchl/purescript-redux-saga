module Redux.Saga (
    sagaMiddleware
  , Saga
  , Saga'
  , SagaPipe
  , SagaThread
  , SagaProc
  , SagaTask
  , IdSupply
  , take
  , fork
  , forkNamed
  , put
  , select
  , joinTask
  , cancel
  , channel
  ) where

import Debug.Trace
import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (Canceler(..), attempt, cancelWith, delay, forkAff, launchAff)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar, makeVar, peekVar, putVar, takeVar, tryPeekVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error, error, stack)
import Control.Monad.Eff.Ref (Ref, REF, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, throwError, catchError)
import Control.Monad.IO (IO, runIO, runIO')
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IO.Effect (INFINITY)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Class (class MonadAsk)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parallel, sequential)
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype)
import Data.Time.Duration (Milliseconds(..))
import Pipes ((>->))
import Pipes as P
import Pipes.Aff (Output)
import Pipes.Aff as P
import Pipes.Core as P
import Pipes.Prelude as P
import React.Redux (REDUX)
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

unsafeCoerceAffA :: ∀ m eff eff2 a. m eff a -> m eff2 a
unsafeCoerceAffA = unsafeCoerce

unsafeCoerceAff' :: ∀ m eff eff2 a. m eff -> m eff2
unsafeCoerceAff' = unsafeCoerce

debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
debugA _ = pure unit
-- debugA = traceAnyA

channel
  :: ∀ input action state
   . String
  -> ((input -> IO Unit) -> IO Unit)
  -> Saga' input action state Unit
  -> Saga' action action state Unit
channel tag cb (Saga' saga) = do
  let log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag <> "): " <> msg

  parentThread <- Saga' $ lift ask

  chan <- liftAff $ P.spawn P.unbounded

  void $ liftAff $ forkAff $ runIO $ do
    childThread <- newThread "channel" parentThread.idSupply parentThread.api
    c <- liftAff $ forkAff $ runIO do
      log "attaching child process (channel)"
      liftAff do
        runIO' $ flip (attachProc $ tag <> " - channel") childThread \input' seal' -> do
          liftAff do
            (runIO' do
              flip runReaderT childThread
                $ P.runEffectRec
                $ P.for (P.fromInput' input' >-> saga) \action -> do
                    lift do
                      liftAff $ delay $ 0.0 # Milliseconds
                      liftEff $ unsafeCoerceEff $ childThread.api.dispatch action
            ) `cancelWith` (Canceler \_ -> true <$ runIO do
                            log "canceling: sealing task"
                            seal'
                            )
      log "saga channel process finished"
    liftIO $ runThread (P.input chan) childThread

  liftIO $ cb (\value -> void $ liftAff $ P.send value chan)

take
  :: ∀ input action state
   . (input -> Maybe (Saga' input action state Unit))
  -> Saga' input action state Unit
take f = Saga' go
  where
  go = map f P.await >>= case _ of
    Just (Saga' saga) -> saga
    Nothing           -> go

put
  :: ∀ input action state
   . action
  -> Saga' input action state Unit
put action = Saga' $ P.yield action

joinTask
  :: ∀ input action state
   . SagaTask
  -> Saga' input action state Unit
joinTask (SagaTask { completionVar }) = Saga' $ liftIO $ liftAff $ takeVar completionVar

cancel
  :: ∀ input action state
   . SagaTask
  -> Saga' input action state Unit
cancel (SagaTask { canceler }) = void do
  -- XXX: Why does the canceler not return?
  liftAff $ forkAff $ Aff.cancel canceler (error "CANCEL_TASK")

select
  :: ∀ input action state
   . Saga' input action state state
select = Saga' do
  { api } <- ask
  liftEff $ unsafeCoerceEff api.getState

fork
  :: ∀ action state
   . Saga' action action state Unit
  -> Saga' action action state SagaTask
fork = forkNamed "anonymous"

forkNamed
  :: ∀ action state
   . String
  -> Saga' action action state Unit
  -> Saga' action action state SagaTask
forkNamed tag saga = do
  thread <- Saga' $ lift ask
  liftIO $ fork' tag thread saga

fork'
  :: ∀ input action state
   . String
  -> SagaThread action action state
  -> Saga' action action state Unit
  -> IO SagaTask
fork' tag parentThread (Saga' saga) = do
  let tag' = parentThread.tag <> ">" <> tag
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg
  completionVar <- liftAff makeVar
  canceler <- liftAff $ forkAff do
    innerCancelerVar <- makeVar

    runIO' $ log "attaching child thread process"
    (runIO' $ flip (attachProc $ tag' <> " - thread") parentThread \input seal -> do
      log "spawning child process (thread)"
      childThread <- newThread tag' parentThread.idSupply parentThread.api
      c <- liftAff $ forkAff $ runIO do
        log "attaching child process (task)"
        liftAff do
          runIO' $ flip (attachProc $ tag' <> " - task") childThread \input' seal' -> do
            liftAff do
              (runIO' do
                flip runReaderT childThread
                  $ P.runEffectRec
                  $ P.for (P.fromInput' input' >-> saga) \action -> do
                      lift do
                        liftAff $ delay $ 0.0 # Milliseconds
                        liftEff $ unsafeCoerceEff $ childThread.api.dispatch action
              ) `cancelWith` (Canceler \_ -> true <$ runIO do
                              log "canceling: sealing task"
                              seal'
                              )
        log "saga process finished"
        seal

      liftAff $ putVar innerCancelerVar c

      log "run thread"
      runThread input childThread

    ) `cancelWith` (Canceler \error ->
      true <$ runIO' do
        liftAff (tryPeekVar innerCancelerVar) >>= case _ of
          Just (Canceler c) -> void do
            log "canceling sub-task"
            liftAff $ c error
          Nothing -> pure unit
    )

    runIO' $ log "run thread finished"
    putVar completionVar unit

  pure $ SagaTask { completionVar, canceler: unsafeCoerceAff' canceler }

type Saga action state a = Saga' action action state a

newtype SagaTask = SagaTask
  { completionVar :: AVar Unit
  , canceler :: Canceler (infinity :: INFINITY)
  }

newtype Saga' input output state a
  = Saga' (
      P.Pipe
        input
        output
        (ReaderT (SagaThread input output state) IO)
        a
    )

derive instance newtypeSaga' :: Newtype (Saga' input action state a) _
derive newtype instance applicativeSaga :: Applicative (Saga' input action state)
derive newtype instance functorSaga :: Functor (Saga' input action state)
derive newtype instance applySaga :: Apply (Saga' input action state)
derive newtype instance bindSaga :: Bind (Saga' input action state)
derive newtype instance monadSaga :: Monad (Saga' input action state)
derive newtype instance monadRecSaga :: MonadRec (Saga' input action state)
derive newtype instance monadThrowSaga :: MonadThrow Error (Saga' input action state)
derive newtype instance monadErrorSaga :: MonadError Error (Saga' input action state)

instance monadIOSaga :: MonadIO (Saga' input action state) where
  liftIO action = Saga' $ liftIO action

instance monadEffSaga :: MonadEff eff (Saga' input action state) where
  liftEff action = Saga' $ liftEff action

instance monadAffSaga :: MonadAff eff (Saga' input action state) where
  liftAff action = Saga' $ liftAff action

type SagaPipe input action state a
  = P.Pipe
      input
      action
      (ReaderT  (SagaThread input action state) IO)
      a

type SagaProc input
  = { id :: Int
    , output :: P.Output input
    , successVar :: AVar Unit
    }

type SagaThread input action state
  = { procsRef :: Ref (Array (SagaProc input))
    , idSupply :: IdSupply
    , failureVar :: AVar Error
    , tag :: String
    , api :: Redux.MiddlewareAPI (infinity :: INFINITY) action state Unit
    }

type Channel a action state
  = { output :: P.Output a
    , input :: P.Input a
    }

newtype IdSupply = IdSupply (Ref Int)

newIdSupply :: IO IdSupply
newIdSupply = IdSupply <$> liftEff (newRef 0)

nextId :: IdSupply -> IO Int
nextId (IdSupply ref) = liftEff $ modifyRef' ref \value -> { state: value + 1, value }

newThread
  :: ∀ input action state
   . String
  -> IdSupply
  -> Redux.MiddlewareAPI (infinity :: INFINITY) action state Unit
  -> IO (SagaThread input action state)
newThread tag idSupply api = do
  failureVar <- liftAff $ makeVar
  procsRef <- liftEff $ newRef []
  pure { tag, idSupply, procsRef, failureVar, api }

runThread
  :: ∀ eff input output state
   . P.Input input
  -> SagaThread input output state
  -> IO Unit
runThread input thread = do
  let log :: String -> IO Unit
      log msg = debugA $ "runThread (" <> thread.tag <> "): " <> msg

  result <- liftAff $ sequential do
    parallel (Just <$> peekVar thread.failureVar) <|> do
      Nothing <$ parallel do
        runIO' do
          log "running input pipe"
          liftAff do
            P.runEffectRec $ P.for (P.fromInput' input) \value -> do
              procs <- liftEff $ readRef thread.procsRef
              lift $ for_ procs \{ output, id } -> do
                P.send' value output
          log "input pipe exhausted"
          procs <- liftEff $ readRef thread.procsRef
          log $ "waiting for " <> show (Array.length procs) <> " processes to finish running..."
          liftAff $ for_ procs (peekVar <<< _.successVar)
          log $ "finished"

  case result of
    Just err -> do
      log $ "finished with error"
      -- TODO: cancel remaining processes
      throwError err
    _ -> void do
      log $ "finished"

attachProc
  :: ∀ eff input output state
   . String
  -> (P.Input input -> IO Unit -> IO Unit)
  -> SagaThread input output state
  -> IO Unit
attachProc tag f thread = do
  id <- nextId $ thread.idSupply

  let log :: String -> IO Unit
      log msg = debugA $ "attachProc (" <> tag <>  ", pid=" <> show id <> "): " <> msg

  chan <- liftAff $ P.spawn P.new
  successVar <- liftAff $ makeVar

  log $ "attaching"
  liftEff $ modifyRef thread.procsRef (_ `Array.snoc` { id, output: P.output chan, successVar })

  liftAff $
    (do
      result <- attempt (runIO $ f (P.input chan) (liftAff $ P.seal chan))
      runIO' $ case result of
        Right _ -> do
          liftAff $ putVar successVar unit
          log $ "succeeded"
        Left e -> do
          log $ "terminated with error"
          let e' = error
                    $ "Process (" <> tag <> ", pid=" <> show id <> ") terminated due to error"
                      <> maybe "" (", stack trace follows:\n" <> _) (stack e)
          liftAff $ putVar thread.failureVar e'
    ) `cancelWith` (Canceler \error -> true <$ runIO do
                      log "canceling..."
                      liftAff $ P.seal chan
                      liftAff $ putVar successVar unit
                   )

{-
  Install and initialize the saga middleware.

  We need the `dispatch` function to run the saga, but we need the saga to get
  the `dispatch` function. To break this cycle, we run an `unsafePerformEff`
  and capture the `dispatch` function immediately.

  Since this has to integrate with react-redux, there's no way to avoid this
  and "redux-saga" does the equivalent hack in it's codebase.
 -}
sagaMiddleware
  :: ∀ action state
   . Saga' action action state Unit
  -> Redux.Middleware _ action state Unit
sagaMiddleware saga api =
  let emitAction
        = unsafePerformEff do
            refOutput <- newRef Nothing
            refCallbacks  <- newRef []
            _ <- launchAff do
              chan <- P.spawn P.new
              callbacks <- liftEff $ modifyRef' refCallbacks \value -> { state: [], value }
              for_ callbacks (_ $ P.output chan)
              liftEff $ modifyRef refOutput (const $ Just $ P.output chan)
              runIO' do
                idSupply <- newIdSupply
                thread <- newThread "root" idSupply api
                task <- fork' "main" thread saga
                flip catchError
                  (\e ->
                    let msg = maybe "" (", stack trace follows:\n" <> _) $ stack e
                    in throwError $ error $ "Saga terminated due to error" <> msg)
                  $ runThread (P.input chan) thread
            pure \action -> void do
              readRef refOutput >>= case _ of
                Just output -> void $ launchAff $ P.send' action output
                Nothing -> void $ modifyRef refCallbacks
                                            (_ `Array.snoc` \output ->
                                              void $ P.send' action output)
   in \next action -> void do
        unsafeCoerceEff $ emitAction action
        next action
