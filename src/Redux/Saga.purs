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
import Control.Monad.Aff (Canceler(Canceler), Error, Fiber, apathize, attempt, bracket, cancelWith, delay, forkAff, generalBracket, joinFiber, killFiber, launchAff, supervise)
import Control.Monad.Aff.AVar (AVAR, AVar, killVar, makeEmptyVar, putVar, readVar, takeVar, tryTakeVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (Error, error, stack)
import Control.Monad.Eff.Exception as Error
import Control.Monad.Eff.Ref (Ref, modifyRef, modifyRef', newRef, readRef)
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
import Data.Array (any)
import Data.Array as A
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe)
import Data.Newtype (class Newtype, unwrap, wrap)
import Data.Time.Duration (Milliseconds(..))
import Data.Traversable (traverse_)
import Data.Tuple (fst)
import Data.Tuple.Nested ((/\), type (/\))
import Debug.Trace (traceAny, traceAnyA)
import Pipes ((>->))
import Pipes (await, for, yield) as P
import Pipes.Aff (Input, Output, fromInput, fromInput', input, new, output, realTime, seal, send, send', spawn) as P
import Pipes.Core (Pipe, runEffectRec) as P
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

unsafeCoerceFiberEff :: ∀ m eff eff2 a. Fiber eff a -> Fiber eff2 a
unsafeCoerceFiberEff = unsafeCoerce

debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
-- debugA _ = pure unit
debugA = traceAnyA

_NOT_IMPLEMENTED_ERROR :: Error
_NOT_IMPLEMENTED_ERROR = error "NOT_IMPLEMENTED"

_COMPLETED_SENTINEL :: Error
_COMPLETED_SENTINEL = error "REDUX_SAGA_COMPLETED"

channel
  :: ∀ env input input' action state a eff
   . String
  -> ((input' -> IO Unit) -> IO Unit)
  -> Saga' env state (Either input input') action a
  -> Saga' env state input action (SagaFiber (Maybe a) eff)
channel tag cb (Saga' saga) = do
  liftAff $ throwError _NOT_IMPLEMENTED_ERROR

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
joinTask (SagaFiber { fiber }) =
  liftAff $
    joinFiber fiber
      `cancelWith` (Canceler \e ->
        killFiber e fiber
      )

cancelTask
  :: ∀ env state input output a eff
   . SagaFiber _ a
  -> Saga' env state input output Unit
cancelTask (SagaFiber { fiber }) = void $
  liftEff $
    launchAff $
      killFiber (error "REDUX_SAGA_CANCEL_TASK") fiber

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
  liftIO $ _fork false tag thread env saga

type KeepAlive = Boolean
type Label = String

-- | Fork a saga off the current thread.
-- We must be sure to safely acquire a new fibre and advertise it to the thread
-- for management. We spawn a completely detached `Aff` computation in order not
-- be directly affected by cancelation handling, but instead to rely on the
-- containing thread to clean this up.
_fork
  :: ∀ env state input output a eff
   . KeepAlive                      -- ^ keep running even with no input
  -> Label                          -- ^ a name tag
  -> ThreadContext state input output  -- ^ the thread we're forking off from
  -> env                            -- ^ the environment for sagas
  -> Saga' env state input output a -- ^ the saga to evaluate
  -> IO (SagaFiber input a)
_fork keepAlive tag thread env (Saga' saga) = do
  let tag' = thread.tag <> ">" <> tag
      log :: String -> IO Unit
      log msg = debugA $ "fork (" <> tag' <> "): " <> msg

  liftAff $ unsafeCoerceAff $
    generalBracket
      (do
        channel   <- unsafeCoerceAff $ P.spawn P.realTime
        channel_1 <- unsafeCoerceAff $ P.spawn P.realTime
        channel_2 <- unsafeCoerceAff $ P.spawn P.realTime

        { channel, fiberId: _, fiber: _ }
          <$> (runIO' $ nextId thread.global.idSupply)
          <*> (liftEff $ launchAff $
                generalBracket
                  (do
                    completionV <- makeEmptyVar
                    childThreadCtx <- runIO' $ newThreadContext thread.global tag'
                    channelPipingFiber <- liftEff $ launchAff $ supervise $ do
                      P.runEffectRec $
                        P.for (P.fromInput channel) \v ->
                          liftAff $ do
                            void $ forkAff $ liftAff $ P.send v channel_1
                            void $ forkAff $ liftAff $ P.send v channel_2
                    childThreadFiber <- liftEff $ launchAff $ do
                      traceAnyA "spawning child thread"
                      runIO' $
                        runThread id (P.input channel_2) childThreadCtx
                    pure { completionV, childThreadFiber, childThreadCtx, channelPipingFiber }
                  )
                  { completed: const \{ completionV, childThreadFiber,  channelPipingFiber } -> do
                      killFiber _COMPLETED_SENTINEL childThreadFiber
                      killVar   _COMPLETED_SENTINEL completionV
                      killFiber _COMPLETED_SENTINEL channelPipingFiber
                      P.seal channel
                  , failed: \e ({ completionV, childThreadFiber, channelPipingFiber }) -> do
                      traceAnyA "fork failed"
                      killFiber e childThreadFiber
                      killFiber e channelPipingFiber
                      killVar   e completionV
                      P.seal channel
                  , killed: \e ({ completionV, childThreadFiber, channelPipingFiber }) -> do
                      traceAnyA "fork cancelled"
                      killFiber e childThreadFiber
                      killFiber e channelPipingFiber
                      killVar   e completionV
                      P.seal channel
                  }
                  \{ completionV, childThreadFiber, childThreadCtx } -> do

                    traceAnyA "evaluating saga..."
                    runIO' $
                      flip runReaderT (env /\ childThreadCtx) $ do
                        P.runEffectRec $
                          P.for (
                            P.fromInput' (P.input channel_1) >-> do
                              saga >>= \val -> traceAny { val } \_ ->
                                liftAff $
                                  putVar val completionV
                          ) \action -> do
                            void $
                              liftEff $
                                unsafeCoerceEff $
                                  thread.global.api.dispatch action

                    traceAnyA "waiting for child..."
                    void $ joinFiber childThreadFiber

                    unless keepAlive $ do
                      traceAnyA "sealing..."
                      P.seal channel

                    traceAnyA "waiting for completion..."
                    takeVar completionV
              )
      )
      { completed: const $ const $ pure unit
      , failed: \e ({ channel, fiber }) -> do
          traceAnyA "error establishing fork"
          unsafeCoerceAff $ P.seal channel
          unsafeCoerceAff $ killFiber e fiber
      , killed: \e ({ channel, fiber }) -> do
          traceAnyA "establishing fork canceld"
          unsafeCoerceAff $ P.seal channel
          unsafeCoerceAff $ killFiber e fiber
      }
      (\{ channel, fiber, fiberId } ->
        let sagaFiber :: ∀ x. Fiber _ x -> SagaFiber input x
            sagaFiber fiber' =
              SagaFiber
                { output: P.output channel
                , fiberId
                , fiber: fiber'
                }
         in sagaFiber (unsafeCoerceFiberEff fiber) <$ do
              -- register this fiber with the tread.
              unsafeCoerceAff $
                liftEff $
                  modifyRef thread.fibersRef $
                    flip Array.snoc (sagaFiber $ void (unsafeCoerceFiberEff fiber))
      )

runThread
  :: ∀ env state input input' output
   . (input -> input')
  -> P.Input input
  -> ThreadContext state input' output
  -> IO Unit
runThread convert input thread =
  let awaitFailureSignal = do
        failure <- makeEmptyVar
        takeVar failure

      awaitActionCompletion = do

        -- we consume the 'input' and pipe all values into all attached fibers.
        -- TODO: capture `fiber` in a bracket and clean up
        _fiber <- liftAff $ forkAff $ void $
          P.runEffectRec $ P.for (P.fromInput' input) \value -> do
            fibers <- liftEff $ readRef thread.fibersRef
            lift $ for_ fibers \(SagaFiber { output }) -> do
              traceAnyA $ thread.tag <> ": sending value along"
              void $ forkAff $ P.send' (convert value) output

        -- wait for any attached processes to start running by repeatedly checking
        -- the mutable `fibersRef` cell and awaiting their computations to
        -- conclude.
        let awaitProcs = do
              fibers <- unsafeCoerceAff $ liftEff $ readRef thread.fibersRef
              unless (Array.null fibers) do
                for_ fibers \(SagaFiber { fiber }) ->
                  joinFiber fiber
                unsafeCoerceAff $ liftEff $
                  modifyRef thread.fibersRef $
                    Array.filter \(SagaFiber { fiberId }) ->
                      not $
                        any (\(SagaFiber { fiberId: fiberId' }) ->
                              fiberId == fiberId') fibers
                awaitProcs

        traceAnyA $ thread.tag <> ": runThread: awaitProcs"
        unsafeCoerceAff awaitProcs

        traceAnyA "runThread: joinFiber"
        unsafeCoerceAff $ joinFiber _fiber

        traceAnyA $ thread.tag <> ": runThread: done"

      awaitCompletion =
        liftAff $ sequential $
          parallel (map Just awaitFailureSignal) <|>
          parallel (Nothing <$ awaitActionCompletion)

   in void $
        liftAff $
          awaitCompletion `cancelWith`
            Canceler \e -> do
              traceAnyA "thread was canceled:"
              traceAnyA e
              fibers <- unsafeCoerceAff $ liftEff $ readRef thread.fibersRef
              unsafeCoerceAff $
                for_ fibers \(SagaFiber { fiber }) ->
                  killFiber e fiber

newThreadContext
  :: ∀ state input action
   . GlobalState state action
  -> Label
  -> IO (ThreadContext state input action)
newThreadContext global tag =
  { global, tag, fibersRef: _ }
    <$> (liftEff $ newRef [])

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
              chan <- P.spawn P.realTime
              callbacks <- liftEff $ modifyRef' refCallbacks \value -> { state: [], value }
              for_ callbacks (_ $ P.output chan)
              liftEff $ modifyRef refOutput (const $ Just $ P.output chan)
              runIO' do
                idSupply <- newIdSupply
                thread <- newThreadContext { idSupply, api: unsafeCoerce api } "root"
                task <- _fork true "main" thread unit saga
                flip catchError
                  (\e ->
                    let msg = maybe "" (", stack trace follows:\n" <> _) $ stack e
                     in throwError $ error $ "Saga terminated due to error" <> msg)
                  $ runThread id (P.input chan) thread

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
