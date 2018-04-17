module Redux.Saga
  ( sagaMiddleware
  , Saga
  , Saga'
  , SagaPipe
  , SagaFiber
  , ThreadContext
  , IdSupply
  , KeepAlive
  , Label
  , GlobalState
  , take
  , takeLatest
  , fork
  , forkNamed
  , fork'
  , forkNamed'
  , put
  , select
  , joinTask
  , cancelTask
  , channel
  , localEnv
  ) where

import Prelude

import Control.Alt (class Alt, (<|>))
import Control.Monad.Aff (Canceler(Canceler), Fiber, apathize, bracket, cancelWith, delay, forkAff, generalBracket, joinFiber, killFiber, launchAff, supervise)
import Control.Monad.Aff.AVar (AVar, killVar, makeEmptyVar, putVar, readVar, takeVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error, error, stack)
import Control.Monad.Eff.Exception as Error
import Control.Monad.Eff.Ref (Ref, modifyRef, modifyRef', newRef, readRef)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, throwError, catchError)
import Control.Monad.IO (IO, runIO')
import Control.Monad.IO.Class (class MonadIO, liftIO)
import Control.Monad.IO.Effect (INFINITY)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Class (class MonadAsk, class MonadReader)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parallel, sequential)
import Data.Array as A
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype, wrap)
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (traverse_)
import Data.Tuple (fst)
import Data.Tuple.Nested ((/\), type (/\))
import Pipes ((>->))
import Pipes (await, for, yield) as P
import Pipes.Aff (Input, Output, fromInput, fromInput', input, output, realTime, seal, send, send', spawn) as P
import Pipes.Core (Pipe, runEffectRec) as P
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

unsafeCoerceFiberEff :: ∀ m eff eff2 a. Fiber eff a -> Fiber eff2 a
unsafeCoerceFiberEff = unsafeCoerce

debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
debugA _ = pure unit
-- debugA = traceAnyA

_NOT_IMPLEMENTED_ERROR :: Error
_NOT_IMPLEMENTED_ERROR = error "NOT_IMPLEMENTED"

_COMPLETED_SENTINEL :: Error
_COMPLETED_SENTINEL = error "REDUX_SAGA_COMPLETED"

_CANCELED_SENTINEL :: Error
_CANCELED_SENTINEL = error "REDUX_SAGA_CANCELLED"

type Emitter input = input -> IO Unit

channel
  :: ∀ env input input' action state a eff
   . String
  -> (Emitter input' -> IO Unit)
  -> Saga' env state (Either input input') action a
  -> Saga' env state input action (SagaFiber input a)
channel tag createEmitter saga =
  let emitter = \emit ->
        createEmitter \input' ->
          emit (Right input')
   in do
      env /\ thread <- Saga' (lift ask)
      liftIO $
        _fork false tag Left emitter thread env saga

take
  :: ∀ env state input output a
   . (input -> Maybe (Saga' env state input output a))
  -> Saga' env state input output a
take f = go
  where
  go = map f (Saga' P.await) >>= case _ of
    Just saga -> saga
    Nothing   -> go

takeLatest
  :: ∀ env state input output a
   . (input -> Maybe (Saga' env state input output a))
  -> Saga' env state input output a
takeLatest f = go Nothing
  where
  go mTask = map f (Saga' P.await) >>= case _ of
    Just saga -> do
      traverse_ cancelTask mTask
      go <<< Just =<< fork saga
    Nothing ->
      go mTask

put
  :: ∀ env input action state
   . action
  -> Saga' env state input action Unit
put action = Saga' do
  liftAff $ delay $ 0.0 # Milliseconds
  P.yield action

joinTask
  :: ∀ env state input output a eff
   . SagaFiber _ a
  -> Saga' env state input output a
joinTask (SagaFiber { fiber, fiberId }) =
  liftAff $
    joinFiber fiber
      `cancelWith` (Canceler \e -> do
        debugA $ "joinTask: killing joined fiber " <> show fiberId
        killFiber e fiber
      )

cancelTask
  :: ∀ env state input output a eff
   . SagaFiber _ a
  -> Saga' env state input output Unit
cancelTask (SagaFiber { fiber }) = void $
  liftAff $ killFiber _CANCELED_SENTINEL fiber

select
  :: ∀ env state input output a
   . Saga' env state input output state
select = do
  _ /\ { global: { api } } <- Saga' (lift ask)
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
  :: ∀ env state input output a eff
   . Saga' env state input output a
  -> Saga' env state input output (SagaFiber input a)
fork = forkNamed "anonymous"

fork'
  :: ∀ env newEnv state input output a eff
   . newEnv
  -> Saga' newEnv state input output a
  -> Saga' env state input output (SagaFiber input a)
fork' = forkNamed' "anonymous"

forkNamed
  :: ∀ env state input output a eff
   . String
  -> Saga' env state input output a
  -> Saga' env state input output (SagaFiber input a)
forkNamed tag saga = do
  env <- ask
  forkNamed' tag env saga

forkNamed'
  :: ∀ env newEnv state input output a eff
   . String
  -> newEnv
  -> Saga' newEnv state input output a
  -> Saga' env state input output (SagaFiber input a)
forkNamed' tag env saga = do
  _ /\ thread <- Saga' (lift ask)
  liftIO $ _fork false tag id (const $ pure unit) thread env saga

type KeepAlive = Boolean
type Label = String

-- | Fork a saga off the current thread.
-- We must be sure to safely acquire a new fibre and advertise it to the thread
-- for management. We spawn a completely detached `Aff` computation in order not
-- be directly affected by cancelation handling, but instead to rely on the
-- containing thread to clean this up.
_fork
  :: ∀ env state input input' output a eff
   . KeepAlive                         -- ^ keep running even with no input
  -> Label                             -- ^ a name tag
  -> (input -> input')                 -- ^ convert upstream values
  -> (Emitter input' -> IO Unit)       -- ^ inject additional values
  -> ThreadContext state input output  -- ^ the thread we're forking off from
  -> env                               -- ^ the environment for sagas
  -> Saga' env state input' output a   -- ^ the saga to evaluate
  -> IO (SagaFiber input a)
_fork keepAlive tag convert inject thread env (Saga' saga) = do
  fiberId <- nextId thread.global.idSupply

  let tag' = thread.tag <> ">" <> tag <> " (" <> show fiberId <> ")"
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg

  liftAff $ unsafeCoerceAff $ do
    generalBracket
      (do
        channel   <- unsafeCoerceAff $ P.spawn P.realTime
        channel_1 <- unsafeCoerceAff $ P.spawn P.realTime
        channel_2 <- unsafeCoerceAff $ P.spawn P.realTime

        { channel, fiberId, fiber: _ }
          <$> (liftEff $ launchAff $
                generalBracket
                  (do
                    completionV <- makeEmptyVar
                    childThreadCtx <- runIO' $ newThreadContext thread.global tag'
                    channelPipingFiber <- liftEff $ launchAff $ supervise $ do
                      P.runEffectRec $
                        P.for (P.fromInput channel) \v ->
                          liftAff $ do
                            void $ forkAff $ apathize $ P.send (convert v) channel_1
                            void $ forkAff $ apathize $ P.send (convert v) channel_2

                   -- TODO: we should supervise the `P.send` forks, but doing so
                   --       appears to block indefinitely. Might be related to
                   --       slamdata/purescript-aff#...
                   -- TODO: change the api to allow users to temrinate a channel
                   --       by sending a sentinel: Emit v = Value v | End
                    userChannelPipingFiber <- liftEff $ launchAff $
                      bracket
                        makeEmptyVar
                        (killVar _COMPLETED_SENTINEL)
                        \endV -> do
                          unsafeCoerceAff $ runIO' $ inject \v -> do
                            liftAff $ do
                              void $ forkAff $ apathize $ P.send v channel_1
                              void $ forkAff $ apathize $ P.send v channel_2
                          takeVar endV

                    childThreadFiber <- liftEff $ launchAff $ do
                      debugA $ tag' <> ": _fork: spawning child thread"
                      runIO' $
                        runThread (P.input channel_2) childThreadCtx (Just completionV)
                      debugA $ tag' <> ": _fork: child thread finished"
                    pure { completionV, childThreadFiber, childThreadCtx, channelPipingFiber, userChannelPipingFiber }
                  )
                  { completed: const \{ completionV, childThreadFiber,  channelPipingFiber, userChannelPipingFiber } -> do
                      debugA $ tag' <> ": _fork: completed: killing child thread..."
                      killFiber _COMPLETED_SENTINEL childThreadFiber
                      debugA $ tag' <> ": _fork: completed: killing completionV..."
                      killVar   _COMPLETED_SENTINEL completionV
                      debugA $ tag' <> ": _fork: completed: killing channel piping fiber..."
                      killFiber _COMPLETED_SENTINEL channelPipingFiber
                      debugA $ tag' <> ": _fork: completed: killing user channel piping fiber..."
                      killFiber _COMPLETED_SENTINEL userChannelPipingFiber
                      debugA $ tag' <> ": _fork: completed: sealing channel..."
                      -- P.seal channel
                      debugA $ tag' <> ": _fork: completed: complete"

                  , failed: \e ({ completionV, childThreadFiber, channelPipingFiber, userChannelPipingFiber }) -> do
                      debugA $ tag' <> ": _fork: failed: killing child thread fiber..."
                      killFiber e childThreadFiber
                      debugA $ tag' <> ": _fork: failed: killing channel piping fiber..."
                      killFiber e channelPipingFiber
                      debugA $ tag' <> ": _fork: failed: killing user channel piping fiber..."
                      killFiber e userChannelPipingFiber
                      debugA $ tag' <> ": _fork: failed: killing completionV..."
                      killVar   e completionV
                      debugA $ tag' <> ": _fork: failed: complete"
                      -- P.seal channel
                  , killed: \e ({ completionV, childThreadFiber, channelPipingFiber, userChannelPipingFiber }) -> do
                      debugA $ tag' <> ": _fork: killed: killing child thread fiber..."
                      killFiber e childThreadFiber
                      debugA $ tag' <> ": _fork: killed: killing channel piping fiber..."
                      killFiber e channelPipingFiber
                      debugA $ tag' <> ": _fork: killed: killing user channel piping fiber..."
                      killFiber e userChannelPipingFiber
                      debugA $ tag' <> ": _fork: killed: killing completionV..."
                      killVar   e completionV
                      debugA $ tag' <> ": _fork: killed: complete"
                      P.seal channel
                  }
                  \{ completionV, childThreadFiber, childThreadCtx } -> do
                    debugA $ tag' <> ": _fork: evaluating saga..."
                    runIO' $
                      flip runReaderT (env /\ childThreadCtx) $ do
                        P.runEffectRec $
                          P.for (
                            P.fromInput' (P.input channel_1) >-> do
                              saga >>= \val -> do
                                liftAff $ do
                                  debugA $ tag' <> ": _fork: signaling completion"
                                  putVar val completionV
                                  debugA $ tag' <> ": _fork: signaled completion"
                          ) \action -> do
                            void $
                              liftEff $
                                unsafeCoerceEff $
                                  thread.global.api.dispatch action

                    debugA $ tag' <> ": _fork: waiting for child..."
                    void $ joinFiber childThreadFiber

                    unless keepAlive $ do
                      debugA $ tag' <> ": _fork: sealing channels..."
                      P.seal channel
                      P.seal channel_1
                      P.seal channel_2

                    debugA $ tag' <> ": _fork: waiting for completion..."
                    result <- takeVar completionV

                    debugA $ tag' <> ": _fork: completed"
                    pure result
              )
      )
      { completed: \v _ -> do
          debugA $ tag' <> ": _fork: fork established"
      , failed: \e ({ channel, fiber }) -> do
          debugA $ tag' <> ": _fork: failed: sealing channel..."
          unsafeCoerceAff $ P.seal channel
          debugA $ tag' <> ": _fork: failed: killing fiber..."
          unsafeCoerceAff $ killFiber e fiber
          debugA $ tag' <> ": _fork: failed: done"
      , killed: \e ({ channel, fiberId, fiber }) -> do
          debugA $ tag' <> ": _fork: killed: sealing channel..."
          unsafeCoerceAff $ P.seal channel
          debugA $ tag' <> ": _fork: killed: killing fiber..."
          unsafeCoerceAff $ killFiber e fiber
          debugA $ tag' <> ": _fork: killed: done"
      }
      (\{ channel, fiber, fiberId } ->
        let sagaFiber :: ∀ x. Fiber _ x -> SagaFiber input x
            sagaFiber fiber' =
              SagaFiber
                { output: P.output channel
                , fiberId
                , fiber: fiber'
                }
         in sagaFiber (unsafeCoerceFiberEff fiber) <$
              let fakeFiber = sagaFiber $ unsafeCoerceFiberEff $ unsafeCoerce fiber
               in do
                  -- synchronously register this fiber with the tread.
                  unsafeCoerceAff $
                    liftEff $
                      modifyRef thread.fibersRef $
                        flip Array.snoc fakeFiber

                  -- and also push-notify the thread that a new fiber was added.
                  putVar (Just fakeFiber) thread.newFiberVar

      )

runThread
  :: ∀ env state input output a
   . P.Input input
  -> ThreadContext state input output
  -> Maybe (AVar a)
  -> IO Unit
runThread input thread completionV =
  liftAff $
    generalBracket
      (do
          { broadcastFiber: _, supervisionFiber: _ }
            <$> (liftEff $ launchAff pipeInputToFibers)
            <*> (liftEff $ launchAff $
                  let go fibers = do
                        debugA $ thread.tag <> ": runThread: supervisor: waiting for fibers..."
                        takeVar thread.newFiberVar >>= case _ of
                          Nothing -> do
                            debugA $ thread.tag <> ": runThread: supervisor: awaiting collected fibers..."
                            for_ fibers joinFiber
                            debugA $ thread.tag <> ": runThread: supervisor: end"
                          Just (sagaFiber@SagaFiber { fiber, fiberId }) -> do
                            debugA $ thread.tag <> ": runThread: supervisor: watching fiber " <> show fiberId
                            fiber <- forkAff $
                              unsafeCoerceAff $ do
                                debugA $ thread.tag <> ": runThread: supervisor: joining fiber " <> show fiberId
                                joinFiber fiber `catchError` \e ->
                                  unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
                                          Error.message e == Error.message _CANCELED_SENTINEL) do
                                    unsafeCoerceAff $ for_ completionV $ killVar e
                                unsafeCoerceAff $ liftEff $ unlinkFiber sagaFiber
                                debugA $ thread.tag <> ": runThread: supervisor: joined fiber " <> show fiberId
                            go (fiber A.: fibers)
                   in go []
                )
      )
      { completed: \e { broadcastFiber, supervisionFiber } -> do
          debugA $ thread.tag <> ": runThread: completed: killing broadcast fiber"
          killFiber _COMPLETED_SENTINEL broadcastFiber
          debugA $ thread.tag <> ": runThread: completed: killing supervision fiber"
          killFiber _COMPLETED_SENTINEL supervisionFiber
          debugA $ thread.tag <> ": runThread: completed: killing remaining fibers"
          unsafeCoerceAff $ killRemainingFibers _COMPLETED_SENTINEL
          debugA $ thread.tag <> ": runThread: completed: completed"
      , failed: \e { broadcastFiber, supervisionFiber } -> do
          debugA $ thread.tag <> ": runThread: failed: killing broadcast fiber"
          killFiber e broadcastFiber
          debugA $ thread.tag <> ": runThread: failed: killing supervision fiber"
          killFiber e supervisionFiber
          debugA $ thread.tag <> ": runThread: failed: killing remaining fibers"
          unsafeCoerceAff $ killRemainingFibers e
          debugA $ thread.tag <> ": runThread: failed: completed"
      , killed: \e { broadcastFiber, supervisionFiber } -> do
          debugA $ thread.tag <> ": runThread: killed: killing broadcast fiber"
          killFiber e broadcastFiber
          debugA $ thread.tag <> ": runThread: killed: killing supervision fiber"
          killFiber e supervisionFiber
          debugA $ thread.tag <> ": runThread: killed: killing remaining fibers"
          unsafeCoerceAff $ killRemainingFibers e
          debugA $ thread.tag <> ": runThread: killed: completed"
      }
      \{ supervisionFiber } -> do

          debugA $ thread.tag <> ": runThread: waiting for completion signal..."
          void $ for_ completionV readVar `catchError` \e ->
            unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
                    Error.message e == Error.message _CANCELED_SENTINEL) do
              throwError e

          debugA $ thread.tag <> ": runThread: signaling end of fibers"
          putVar Nothing thread.newFiberVar
          debugA $ thread.tag <> ": runThread: signaled end of fibers"

          debugA $ thread.tag <> ": runThread: waiting for supervision fiber..."
          joinFiber supervisionFiber `catchError` \e ->
            unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
                    Error.message e == Error.message _CANCELED_SENTINEL) do
              throwError e

          debugA $ thread.tag <> ": runThread: done"

  where
  killRemainingFibers e = do
    fibers <- unsafeCoerceAff $ liftEff $ readRef thread.fibersRef
    for_ fibers \(SagaFiber { fiber, fiberId }) -> do
      debugA $ thread.tag <> ": runThread: killRemainingFibers: killing " <> show fiberId <> " ..."
      -- Note: Need to start a kill this fiber in a fresh Aff context to avoid
      --       potentially causing an error while running the finalizer.
      -- TODO: Spend more time understanding this. What are the implications?
      -- Refer: https://github.com/slamdata/purescript-aff/blob/master/src/Control/Monad/Aff.js#L502-L505
      void $ liftEff $ launchAff $ killFiber e fiber
      debugA $ thread.tag <> ": runThread: killRemainingFibers: killed " <> show fiberId <> " ..."

  unlinkFiber (SagaFiber { fiberId }) =
    modifyRef thread.fibersRef $
      Array.filter \(SagaFiber { fiberId: fiberId' }) ->
        not $ fiberId == fiberId'

  pipeInputToFibers =
    P.runEffectRec $ P.for (P.fromInput' input) \value -> do
      fibers <- liftEff $ readRef thread.fibersRef
      lift $ for_ fibers \(SagaFiber { output }) -> do
        debugA $ thread.tag <> ": runThread: sending value along"
        void $ forkAff $ apathize $ P.send' value output

newThreadContext
  :: ∀ state input action
   . GlobalState state action
  -> Label
  -> IO (ThreadContext state input action)
newThreadContext global tag =
  { global, tag, fibersRef: _, newFiberVar: _ }
    <$> (liftEff $ newRef [])
    <*> (liftAff makeEmptyVar)

type Saga env state action a = Saga' env state action action a

newtype Saga' env state input output a
  = Saga' (
      P.Pipe
        input
        output
        (ReaderT (env /\ (ThreadContext state input output)) IO)
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

instance altSaga :: Alt (Saga' env state input action) where
  alt s1 s2 = do
    t1@(SagaFiber { fiber: f1 }) <- forkNamed "L" s1
    t2@(SagaFiber { fiber: f2 }) <- forkNamed "R" s2
    result <- liftAff do
      sequential $
        parallel (Left  <$> joinFiber f1) <|>
        parallel (Right <$> joinFiber f2)
    case result of
      Left  v -> v <$ cancelTask t2
      Right v -> v <$ cancelTask t1

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
      (ReaderT (env /\ (ThreadContext state input action)) IO)
      a

type GlobalState state action
  = { idSupply :: IdSupply
    , api :: Redux.MiddlewareAPI (infinity :: INFINITY) state action
    }

-- | A `SagaFiber` is a single computation.
newtype SagaFiber input a
  = SagaFiber
      { fiberId :: Int
      , output :: P.Output input
      , fiber :: Fiber (infinity :: INFINITY) a
      }

-- | A `ThreadContext` is a collection of saga fibers.
type ThreadContext state input action
  = { global :: GlobalState state action
    , tag :: String
    , fibersRef :: Ref (Array (SagaFiber input Unit))
    , newFiberVar :: AVar (Maybe (SagaFiber input Unit))
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

{-|
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
              chan      <- P.spawn P.realTime
              callbacks <- liftEff $ modifyRef' refCallbacks \value -> { state: [], value }
              for_ callbacks (_ $ P.output chan)
              liftEff $ modifyRef refOutput (const $ Just $ P.output chan)
              runIO' do
                idSupply  <- newIdSupply
                threadCtx <- newThreadContext { idSupply, api: unsafeCoerce api } "root"
                task      <- _fork true "main" id (const $ pure unit) threadCtx unit saga
                runThread (P.input chan) threadCtx Nothing
                  `catchError` \e ->
                    let msg = maybe "" (", stack trace follows:\n" <> _) $ stack e
                     in throwError $ error $ "Saga terminated due to error" <> msg
            pure \action -> void do
              readRef refOutput >>= case _ of
                Just output ->
                  void $
                    launchAff $ do
                      delay $ 0.0 # Milliseconds
                      P.send' action output
                Nothing -> do
                  void $
                    modifyRef refCallbacks
                      (_ `Array.snoc` \output ->
                        void $ P.send' action output)
   in \next action -> void do
        unsafeCoerceEff $ emitAction action
        next action
