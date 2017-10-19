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
  , cancelTask
  , channel
  ) where

import Debug.Trace
import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (Canceler(..), Fiber, killFiber, joinFiber, attempt, cancelWith, delay, forkAff, launchAff)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar, AVAR, makeEmptyVar, readVar, putVar, takeVar, tryReadVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error, error, stack)
import Control.Monad.Eff.Ref (Ref, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, throwError, catchError)
import Control.Monad.IO (IO, runIO, runIO')
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IO.Effect (INFINITY)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parallel, sequential)
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype, wrap)
import Data.Time.Duration (Milliseconds(..))
import Data.Tuple.Nested ((/\))
import Global (infinity)
import Pipes ((>->))
import Pipes as P
import Pipes.Aff as P
import Pipes.Core as P
import React.Redux (ReduxEffect)
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)


unsafeCoerceFiberEff :: ∀ m eff eff2 a. Fiber eff a -> Fiber eff2 a
unsafeCoerceFiberEff = unsafeCoerce

debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
debugA _ = pure unit
-- debugA = traceAnyA

channel
  :: ∀ input action state
   . String
  -> ((input -> IO Unit) -> IO Unit)
  -> Saga' state input action Unit
  -> Saga' state action action Unit
channel tag cb (Saga' saga) = do
  let log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag <> "): " <> msg

  childThread <- newThread' "channel"

  chan <- liftAff $ P.spawn P.new

  void $ liftAff $ forkAff $ runIO $ do
    c <- liftAff $ forkAff $ runIO do
      log "attaching child process (channel)"
      liftAff do
        runIO' $ flip (attachProc $ tag <> " - channel") childThread \input' seal' -> do
          liftAff do
            (runIO' do
              flip runReaderT childThread
                $ P.runEffectRec
                $ P.for (P.fromInput' input' >-> saga) \action -> do
                    void $ liftEff $ unsafeCoerceEff $ childThread.api.dispatch action
            ) `cancelWith` (Canceler \_ -> void $ runIO do
                            log "canceling: sealing task"
                            seal'
                            )
      log "saga channel process finished"
    liftIO $ runThread (P.input chan) childThread

  liftIO $ cb (\value -> void $ liftAff $ forkAff $ P.send value chan)

take
  :: ∀ state input output a
   . (input -> Maybe (Saga' state input output a))
  -> Saga' state input output a
take f = Saga' go
  where
  go = map f P.await >>= case _ of
    Just (Saga' saga) -> saga
    Nothing           -> go

put
  :: ∀ input action state
   . action
  -> Saga' state input action Unit
put action = Saga' do
  liftAff $ delay $ 0.0 # Milliseconds
  P.yield action

joinTask
  :: ∀  state input output
   . SagaTask
  -> Saga' state input output Unit
joinTask (SagaTask fiber) = liftIO $ liftAff do
  joinFiber fiber

cancelTask
  :: ∀  state input output
   . SagaTask
  -> Saga' state input output Unit
cancelTask (SagaTask fiber) = void $ liftAff do
  killFiber (error "CANCEL_TASK") fiber

select
  :: ∀ state input output
   . Saga' state input output state
select = do
  { api } <- Saga' $ lift ask
  liftEff api.getState

fork
  :: ∀ state input output
   . Saga' state input output Unit
  -> Saga' state input output SagaTask
fork = forkNamed "anonymous"

forkNamed
  :: ∀  state input output
   . String
  -> Saga' state input output Unit
  -> Saga' state input output SagaTask
forkNamed tag saga = do
  thread <- Saga' $ lift ask
  liftIO $ fork' false tag thread saga

fork'
  :: ∀ state input output
   . Boolean
  -> String
  -> SagaThread state input output
  -> Saga' state input output Unit
  -> IO SagaTask
fork' keepAlive tag parentThread (Saga' saga) = do
  let tag' = parentThread.tag <> ">" <> tag
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg
  fiber <- liftAff $ forkAff do
    runIO' $ log "attaching child thread process"
    runIO' $ flip (attachProc $ tag' <> " - thread") parentThread \input seal -> do
      log "spawning child process (thread)"
      childThread <- newThread tag' parentThread.idSupply parentThread.api
      void $ liftAff $ forkAff $ runIO do
        log "attaching child process (task)"
        liftAff do
          runIO' $ flip (attachProc $ tag' <> " - task") childThread \input' seal' -> do
            liftAff do
              runIO' do
                flip runReaderT childThread
                  $ P.runEffectRec
                  $ P.for (P.fromInput' input' >-> saga) \action -> do
                      void $ liftEff $ unsafeCoerceEff $ childThread.api.dispatch action
        log "saga process finished"
      log "run thread"

      runThread input childThread
      log "run thread finished"

      unless keepAlive do
        log "sealing..."
        seal

  pure $ SagaTask (unsafeCoerceFiberEff fiber)

type Saga state action a = Saga' state action action a

newtype SagaTask = SagaTask (Fiber (avar :: AVAR) Unit)

newtype Saga' state input output a
  = Saga' (
      P.Pipe
        input
        output
        (ReaderT (SagaThread state input output) IO)
        a
    )

derive instance newtypeSaga' :: Newtype (Saga' state input action a) _
derive newtype instance applicativeSaga :: Applicative (Saga' state input action)
derive newtype instance functorSaga :: Functor (Saga' state input action)
derive newtype instance applySaga :: Apply (Saga' state input action)
derive newtype instance bindSaga :: Bind (Saga' state input action)
derive newtype instance monadSaga :: Monad (Saga' state input action)
derive newtype instance monadRecSaga :: MonadRec (Saga' state input action)
derive newtype instance monadThrowSaga :: MonadThrow Error (Saga' state input action)
derive newtype instance monadErrorSaga :: MonadError Error (Saga' state input action)

instance monadIOSaga :: MonadIO (Saga' state input action) where
  liftIO action = Saga' $ liftIO action

instance monadEffSaga :: MonadEff eff (Saga' state input action) where
  liftEff action = Saga' $ liftEff action

instance monadAffSaga :: MonadAff eff (Saga' state input action) where
  liftAff action = Saga' $ liftAff action

type SagaPipe state input action a
  = P.Pipe
      input
      action
      (ReaderT  (SagaThread state input action) IO)
      a

type SagaProc input
  = { id :: Int
    , output :: P.Output input
    , successVar :: AVar Unit
    }

type SagaThread state input action
  = { procsRef :: Ref (Array (SagaProc input))
    , idSupply :: IdSupply
    , failureVar :: AVar Error
    , tag :: String
    , api :: Redux.MiddlewareAPI (infinity :: INFINITY) state action
    }

type Channel a state action
  = { output :: P.Output a
    , input :: P.Input a
    }

newtype IdSupply = IdSupply (Ref Int)

newIdSupply :: IO IdSupply
newIdSupply = IdSupply <$> liftEff (newRef 0)

nextId :: IdSupply -> IO Int
nextId (IdSupply ref) = liftEff $ modifyRef' ref \value -> { state: value + 1, value }

newThread
  :: ∀ state input output
   . String
  -> IdSupply
  -> Redux.MiddlewareAPI (infinity :: INFINITY) state output
  -> IO (SagaThread state input output)
newThread tag idSupply api = do
  failureVar <- liftAff $ makeEmptyVar
  procsRef <- liftEff $ newRef []
  pure { tag, idSupply, procsRef, failureVar, api }

newThread'
  :: ∀  state input' input output
   . String
  -> Saga' state input output (SagaThread state input' output)
newThread' tag = do
  { idSupply, api } <- Saga' $ lift ask
  failureVar <- liftAff $ makeEmptyVar
  procsRef <- liftEff $ newRef []
  pure { tag, idSupply, procsRef, failureVar, api }

runThread
  :: ∀ state input output
   . P.Input input
  -> SagaThread state input output
  -> IO Unit
runThread input thread = do
  let log :: String -> IO Unit
      log msg = debugA $ "runThread (" <> thread.tag <> "): " <> msg

  result <- liftAff $ sequential do
    parallel (Just <$> readVar thread.failureVar) <|> do
      Nothing <$ parallel do
        runIO' do
          log "running input pipe"
          void $ liftAff $ forkAff do
            P.runEffectRec $ P.for (P.fromInput' input) \value -> do
              procs <- liftEff $ readRef thread.procsRef
              lift $ for_ procs \{ output, id } -> do
                runIO' $ log $ "sending value downstream to: pid "  <> show id
                void $ forkAff $ P.send' value output
            runIO' $ log "input pipe exhausted"
          procs <- liftEff $ readRef thread.procsRef
          log $ "waiting for " <> show (Array.length procs) <> " processes to finish running..."
          liftAff $ for_ procs (readVar <<< _.successVar)
          log $ "finished"

  case result of
    Just err -> do
      log $ "finished with error"
      -- TODO: cancel remaining processes
      throwError err
    _ -> void do
      log $ "finished"

attachProc
  :: ∀ state input output
   . String
  -> (P.Input input -> IO Unit -> IO Unit)
  -> SagaThread state input output
  -> IO Unit
attachProc tag f thread = do
  id <- nextId $ thread.idSupply

  let log :: String -> IO Unit
      log msg = debugA $ "attachProc (" <> tag <>  ", pid=" <> show id <> "): " <> msg

  chan <- liftAff $ P.spawn P.new
  successVar <- liftAff $ makeEmptyVar

  log $ "attaching"
  liftEff $ modifyRef thread.procsRef (_ `Array.snoc` { id, output: P.output chan, successVar })

  liftAff $
    (do
      result <- attempt (runIO $ f (P.input chan) ({-liftAff $ P.seal chan-} pure unit))
      runIO' $ case result of
        Right _ -> do
          liftAff $ putVar unit successVar
          log $ "succeeded"
        Left e -> do
          log $ "terminated with error"
          let e' = error
                    $ "Process (" <> tag <> ", pid=" <> show id <> ") terminated due to error"
                      <> maybe "" (", stack trace follows:\n" <> _) (stack e)
          liftAff $ putVar e' thread.failureVar
    ) `cancelWith` (Canceler \error -> void $ runIO do
                      log "canceling..."
                      liftAff $ P.seal chan
                      liftAff $ putVar unit successVar
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
  :: ∀ action state eff
   . Saga' state action action Unit
  -> Redux.Middleware eff state action _ _ -- action action
sagaMiddleware saga = wrap $ \api ->
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
                thread <- newThread "root" idSupply (unsafeCoerce api)
                task <- fork' true "main" thread saga
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
