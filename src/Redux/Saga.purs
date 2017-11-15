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
  , localEnv
  ) where

import Debug.Trace
import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (Canceler(..), Fiber, attempt, cancelWith, delay, forkAff, joinFiber, killFiber, launchAff, supervise)
import Control.Monad.Aff as Aff
import Control.Monad.Aff.AVar (AVar, AVAR, makeEmptyVar, readVar, putVar, tryTakeVar, takeVar, tryReadVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error, error, stack)
import Control.Monad.Eff.Exception as Error
import Control.Monad.Eff.Ref (Ref, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, throwError, catchError)
import Control.Monad.IO (IO, runIO, runIO')
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IO.Effect (INFINITY)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Class (class MonadAsk, class MonadReader)
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
import Data.Tuple (fst)
import Data.Tuple.Nested ((/\), type (/\))
import Global (infinity)
import Pipes ((>->))
import Pipes as P
import Pipes.Aff (fromInput)
import Pipes.Aff as P
import Pipes.Core as P
import React.Redux (ReduxEffect)
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

unsafeCoerceFiberEff :: ∀ m eff eff2 a. Fiber eff a -> Fiber eff2 a
unsafeCoerceFiberEff = unsafeCoerce

debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
debugA _ = pure unit

channel
  :: ∀ env input input' action state a
   . String
  -> ((input' -> IO Unit) -> IO Unit)
  -> Saga' env state (Either input input') action a
  -> Saga' env state input action (SagaTask (Maybe a))
channel tag cb (Saga' saga) = do
  env /\ parentThread  <- Saga' $ lift ask

  let tag' = parentThread.tag <> ">" <> tag
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg

  chan <- liftAff $ P.spawn P.new

  fiber <- liftAff $ forkAff $ runIO do
    completionV :: AVar a <- liftAff $ makeEmptyVar
    log "attaching child"

    flip (attach $ tag' <> " - thread") parentThread \input seal -> do
      log "spawning child process (thread)"
      childThread <- liftIO $ mkThread tag' parentThread.idSupply parentThread.api

      f1 <- liftAff $ forkAff $
        runIO' $ flip (attach $ tag' <> " - task") childThread \input' seal' ->
          void $ liftAff $
            P.runEffectRec $
              P.for (P.fromInput' input') \action ->
                void $ liftAff $ forkAff $ P.send action chan

      f2 <- liftAff $ forkAff $ runIO $
        liftAff $
          runIO' $
            flip runReaderT (env /\ childThread) $
              P.runEffectRec $
                P.for (P.fromInput chan >-> do
                  saga >>= liftAff <<< flip putVar completionV
                ) \action ->
                  void $ liftEff $
                    unsafeCoerceEff $
                      childThread.api.dispatch action

      runThread Left input childThread
      seal
      liftAff $ joinFiber f1
      liftAff $ joinFiber f2
      pure unit

    liftAff $ tryTakeVar completionV

  liftIO $ cb (\value -> void $ liftAff $ forkAff $ P.send (Right value) chan)

  pure $ SagaTask (unsafeCoerceFiberEff fiber)

take
  :: ∀ env state input output a
   . (input -> Maybe (Saga' env state input output a))
  -> Saga' env state input output a
take f = Saga' go
  where
  go = map f P.await >>= case _ of
    Just (Saga' saga) -> saga
    Nothing           -> go

put
  :: ∀ env input action state
   . action
  -> Saga' env state input action Unit
put action = Saga' do
  liftAff $ delay $ 0.0 # Milliseconds
  P.yield action

joinTask
  :: ∀ env state input output a
   . SagaTask a
  -> Saga' env state input output a
joinTask (SagaTask fiber) = liftAff $ joinFiber fiber

cancelTask
  :: ∀ env state input output a
   . SagaTask a
  -> Saga' env state input output Unit
cancelTask (SagaTask fiber) = void $ liftAff do
  killFiber (error "REDUX_SAGA_CANCEL_TASK") fiber

select
  :: ∀ env state input output a
   . Saga' env state input output state
select = do
  _ /\ { api } <- Saga' (lift ask)
  liftEff api.getState

localEnv
  :: ∀ env env2 state input output a
   . (env -> env2)
  -> Saga' env2 state input output a
  -> Saga' env state input output a
localEnv f saga = do
  env <- ask
  joinTask =<< fork' (f env) saga

fork
  :: ∀ env state input output a
   . Saga' env state input output a
  -> Saga' env state input output (SagaTask a)
fork = forkNamed "anonymous"

fork'
  :: ∀ env newEnv state input output a
   . newEnv
  -> Saga' newEnv state input output a
  -> Saga' env state input output (SagaTask a)
fork' = forkNamed' "anonymous"

forkNamed
  :: ∀ env state input output a
   . String
  -> Saga' env state input output a
  -> Saga' env state input output (SagaTask a)
forkNamed tag saga = do
  env <- ask
  forkNamed' tag env saga

forkNamed'
  :: ∀ env newEnv state input output a
   . String
  -> newEnv
  -> Saga' newEnv state input output a
  -> Saga' env state input output (SagaTask a)
forkNamed' tag env saga = do
  _ /\ thread <- Saga' (lift ask)
  liftIO $ _fork false tag thread env saga

_fork
  :: ∀ env state input output a
   . Boolean
  -> String
  -> SagaThread state input output
  -> env
  -> Saga' env state input output a
  -> IO (SagaTask a)
_fork keepAlive tag parentThread env (Saga' saga) = do
  let tag' = parentThread.tag <> ">" <> tag
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg

  childThread <- mkThread tag' parentThread.idSupply parentThread.api
  fiber <- liftAff $ forkAff $ supervise $ runIO do
    completionV <- liftAff $ makeEmptyVar
    log "attaching child"
    flip (attach $ tag' <> " - thread") parentThread \input seal -> do
      log "spawning child process (thread)"
      f1 <- liftAff $ forkAff $ runIO do
        log "attaching child process (task)"
        liftAff $
          runIO' $ flip (attach $ tag' <> " - task") childThread \input' seal' ->
            liftAff $
              runIO' $
                flip runReaderT (env /\ childThread) $ do
                  P.runEffectRec $
                    P.for (P.fromInput' input' >-> do
                      saga >>= liftAff <<< flip putVar completionV
                    ) \action -> do
                      void $ liftEff $ unsafeCoerceEff $ childThread.api.dispatch action
      runThread id input childThread
      unless keepAlive seal
      void $ liftAff $ joinFiber f1
    liftAff $ takeVar completionV

  pure $ SagaTask (unsafeCoerceFiberEff fiber)

type Saga env state action a = Saga' env state action action a

newtype SagaTask a = SagaTask (Fiber (avar :: AVAR) a)

newtype Saga' env state input output a
  = Saga' (
      P.Pipe
        input
        output
        (ReaderT (env /\ (SagaThread state input output)) IO)
        a
    )

derive instance newtypeSaga' :: Newtype (Saga' env state input action a) _
derive newtype instance applicativeSaga :: Applicative (Saga' env state input action)
derive newtype instance functorSaga :: Functor (Saga' env state input action)
derive newtype instance applySaga :: Apply (Saga' env state input action)
derive newtype instance bindSaga :: Bind (Saga' env state input action)
derive newtype instance monadSaga :: Monad (Saga' env state input action)
derive newtype instance monadRecSaga :: MonadRec (Saga' env state input action)
derive newtype instance monadThrowSaga :: MonadThrow Error (Saga' env state input action)
derive newtype instance monadErrorSaga :: MonadError Error (Saga' env state input action)

instance monadAskSaga :: MonadAsk env (Saga' env state input action) where
  ask = fst <$> Saga' (lift ask)

instance monadReaderSaga :: MonadReader env (Saga' env state input action) where
  local f saga = do
    env <- ask
    joinTask =<< fork' (f env) saga

instance monadIOSaga :: MonadIO (Saga' env state input action) where
  liftIO action = Saga' $ liftIO action

instance monadEffSaga :: MonadEff eff (Saga' env state input action) where
  liftEff action = Saga' $ liftEff action

instance monadAffSaga :: MonadAff eff (Saga' env state input action) where
  liftAff action = Saga' $ liftAff action

type SagaPipe env state input action a
  = P.Pipe
      input
      action
      (ReaderT (env /\ (SagaThread state input action)) IO)
      a

type SagaProc input
  = { id :: Int
    , output :: P.Output input
    , successVar :: AVar Unit
    , fiber :: Fiber (infinity :: INFINITY) Unit
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

mkThread
  :: ∀ state input output
   . String
  -> IdSupply
  -> Redux.MiddlewareAPI (infinity :: INFINITY) state output
  -> IO (SagaThread state input output)
mkThread tag idSupply api = do
  failureVar <- liftAff $ makeEmptyVar
  procsRef   <- liftEff $ newRef []
  pure { tag, idSupply, procsRef, failureVar, api }

runThread
  :: ∀ env state input input' output
   . (input -> input')
  -> P.Input input
  -> SagaThread state input' output
  -> IO Unit
runThread f input thread = do
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
                void $ forkAff $ P.send' (f value) output
            runIO' $ log "input pipe exhausted"
          procs <- liftEff $ readRef thread.procsRef
          log $ "waiting for " <> show (Array.length procs) <> " processes to finish running..."
          liftAff $ for_ procs (readVar <<< _.successVar)
          log $ "finished"

  case result of
    Just err -> do
      if Error.message err == "REDUX_SAGA_CANCEL_TASK"
        then log $ "canceled"
        else do
          log $ "finished with error"
          throwError err

      log "canceling processes"
      procs <- liftEff $ readRef thread.procsRef
      liftAff $ for_ procs (killFiber err <<< _.fiber)
    _ -> void do
      log $ "finished"

attach
  :: ∀ state input output a
   . String
  -> (P.Input input -> IO Unit -> IO a)
  -> SagaThread state input output
  -> IO Unit
attach tag f thread = do
  id <- nextId $ thread.idSupply

  let log :: String -> IO Unit
      log msg = debugA $ "attach (" <> tag <>  ", pid=" <> show id <> "): " <> msg

  chan <- liftAff $ P.spawn P.new
  successVar <- liftAff $ makeEmptyVar

  log $ "attaching"

  fiber <- liftAff $ forkAff do
    result <- attempt $ runIO $ f (P.input chan) (liftAff $ P.seal chan)
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

  liftEff $ modifyRef thread.procsRef (_ `Array.snoc`
                                          { id, output: P.output chan
                                          , successVar
                                          , fiber
                                          })
  liftAff $
    (joinFiber fiber)
      `cancelWith` (Canceler \error -> void $ runIO do
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
   . Saga' Unit state action action Unit
  -> Redux.Middleware eff state action _ _
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
                thread <- mkThread "root" idSupply (unsafeCoerce api)
                task <- _fork true "main" thread unit saga
                flip catchError
                  (\e ->
                    let msg = maybe "" (", stack trace follows:\n" <> _) $ stack e
                     in throwError $ error $ "Saga terminated due to error" <> msg)
                  $ runThread id (P.input chan) thread
            pure \action -> void do
              readRef refOutput >>= case _ of
                Just output -> void $ launchAff $ P.send' action output
                Nothing -> void $ modifyRef refCallbacks
                                            (_ `Array.snoc` \output ->
                                              void $ P.send' action output)
   in \next action -> void do
        unsafeCoerceEff $ emitAction action
        next action
