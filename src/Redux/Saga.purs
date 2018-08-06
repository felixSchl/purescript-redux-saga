module Redux.Saga where
--   ( sagaMiddleware

--   -- * types
--   , Saga
--   , Saga'
--   , SagaPipe
--   , SagaFiber
--   , ThreadContext
--   , IdSupply
--   , KeepAlive
--   , Label
--   , GlobalState

--   -- * combinators
--   , take
--   , takeLatest
--   , fork
--   , forkNamed
--   , fork'
--   , forkNamed'
--   , put
--   , select
--   , joinTask
--   , cancelTask
--   , channel
--   , localEnv
--   ) where

import Prelude

import Control.Monad.Reader (ReaderT(..), ask, runReaderT, withReaderT)
import Control.Monad.Rec.Class (forever)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, wrap)
import Data.Time.Duration (Milliseconds(..))
import Debug.Trace (traceM)
import Effect.Aff (Aff, delay, launchAff_, try)
import Effect.Aff.Bus as Bus
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import Effect.Unsafe (unsafePerformEffect)
import React.Redux as Redux
-- import Unsafe.Coerce (unsafeCoerce)

-- unsafeCoerceFiberEff :: ∀ m eff eff2 a. Fiber eff a -> Fiber eff2 a
-- unsafeCoerceFiberEff = unsafeCoerce

-- debugA :: ∀ a b. Show b => Applicative a => b -> a Unit
-- debugA _ = pure unit
-- -- debugA = traceAnyA

-- _COMPLETED_SENTINEL :: Error
-- _COMPLETED_SENTINEL = error "REDUX_SAGA_COMPLETED"

-- _CANCELED_SENTINEL :: Error
-- _CANCELED_SENTINEL = error "REDUX_SAGA_CANCELLED"

-- type KeepAlive = Boolean
-- type Label = String

-- -- | A name tag assigned to a saga
-- type NameTag = String

-- -- | A function to emit values into a channel
-- type Emitter input = input -> IO Unit

-- -- | Forks a new saga, providing the caller with an `Emitter`, allowing them to
-- -- | inject arbitrary values into the forked saga. To discern between upstream
-- -- | values and injected values, values are tagged `Left` and `Right`
-- -- | respectively.
-- channel
--   :: ∀ env input input' action state a eff
--    . NameTag
--   -> (Emitter input' -> IO Unit)
--   -> Saga' env state (Either input input') action a
--   -> Saga' env state input action (SagaFiber input a)
-- channel tag createEmitter saga =
--   let emitter = \emit ->
--         createEmitter \input' ->
--           emit (Right input')
--    in do
--       env /\ thread <- Saga' (lift ask)
--       liftIO $
--         _fork false tag Left emitter thread env saga

-- | `take` blocks to receive an input value for which the given function
-- | returns `Just` a saga to execute. This saga is then executed on the same
-- | thread, blocking until it finished running.
-- |
-- | #### Example
-- |
-- | ``` purescript
-- | data Action = SayFoo | SayBar
-- |
-- | sayOnlyBar
-- |   :: ∀ env state Action Action
-- |    . Saga' env state Action Action Unit
-- | sayOnlyBar = do
-- |   take case _ of
-- |     SayFoo -> Nothing
-- |     SayBar -> Just do
-- |       liftEff $ Console.log "Bar!"
-- | ```
take
  :: ∀ env state input output a
   . (input -> Maybe (Saga' env state input output a))
  -> Saga' env state input output a
take f = do
  { inputBus } <- ask
  go inputBus

  where
  go bus = go'
    where
    go' =
      map f (liftAff (Bus.read bus)) >>= case _ of
        Nothing ->
          go'
        Just saga ->
          saga

  -- where
  -- go = map f (Saga' P.await) >>= case _ of
  --   Just saga -> saga
  --   Nothing   -> go

-- -- | Similar to `take` but runs indefinitely, replacing previously spawned tasks
-- -- | with new ones.
-- takeLatest
--   :: ∀ env state input output a
--    . (input -> Maybe (Saga' env state input output a))
--   -> Saga' env state input output a
-- takeLatest f = go Nothing
--   where
--   go mTask = map f (Saga' P.await) >>= case _ of
--     Just saga -> do
--       traverse_ cancelTask mTask
--       go <<< Just =<< fork saga
--     Nothing ->
--       go mTask

-- | `put` emits an `output` which gets dispatched to your redux store and in
-- | turn becomes available to sagas.
-- |
-- | #### Example
-- |
-- | ``` purescript
-- | data Action = SayFoo | SayBar
-- |
-- | sayOnlyBar
-- |   :: ∀ env state
-- |    . Saga' env state Action Action Unit
-- | sayOnlyBar = do
-- |
-- |   put SayBar -- ^ trigger a `SayBar` action right away.
-- |
-- |   take case _ of
-- |     SayFoo -> Nothing
-- |     SayBar -> Just do
-- |       liftEff $ Console.log "Bar!"
-- |
-- | -- >> Bar!
-- | ```
put
  :: ∀ env input action state
   . action
  -> Saga' env state input action Unit
put action = do
  { api } <- ask
  liftAff $ delay $ 0.0 # Milliseconds
  void $ liftEffect $ api.dispatch action

-- -- | `joinTask` blocks until a given `SagaTask` returns.
-- -- |
-- -- | *NOTE:* Canceling the joining of a task will also cancel the task itself.
-- -- |
-- -- | #### Example
-- -- |
-- -- | ``` purescript
-- -- | helloWorld
-- -- |   :: ∀ env state input output
-- -- |    . Saga' env state input output Unit
-- -- | helloWorld = do
-- -- |   task <- fork $ do
-- -- |     liftAff $ delay $ 10000.0 # Milliseconds
-- -- |     liftAff $ Console.log "World!"
-- -- |   joinTask task
-- -- |   liftEff $ Console.log "Hello"
-- -- |
-- -- | -- >> World!
-- -- | -- >> Hello
-- -- | ```
-- joinTask
--   :: ∀ env state input output a eff
--    . SagaFiber _ a
--   -> Saga' env state input output a
-- joinTask (SagaFiber { fiber, fiberId }) =
--   liftAff $
--     joinFiber fiber
--       `cancelWith` (Canceler \e -> do
--         debugA $ "joinTask: killing joined fiber " <> show fiberId
--         killFiber e fiber
--       )

-- -- | `cancelTask` cancels a given `SagaTask`.
-- -- |
-- -- | #### Example
-- -- |
-- -- | ``` purescript
-- -- | helloWorld
-- -- |   :: ∀ env state input output
-- -- |    . Saga' env state input output Unit
-- -- | helloWorld = do
-- -- |   task <- fork $ do
-- -- |     liftAff $ delay $ 10000.0 # Milliseconds
-- -- |     liftAff $ Console.log "World!"
-- -- |   cancelTask task
-- -- |   liftEff $ Console.log "Hello"
-- -- |
-- -- | -- >> Hello
-- -- | ```
-- cancelTask
--   :: ∀ env state input output a eff
--    . SagaFiber _ a
--   -> Saga' env state input output Unit
-- cancelTask (SagaFiber { fiber }) = void $
--   liftAff $ killFiber _CANCELED_SENTINEL fiber

-- -- | `select` gives access the the current application state and it's output
-- -- | varies over time as the application state changes.
-- -- |
-- -- | #### Example
-- -- |
-- -- | ``` purescript
-- -- | printState
-- -- |   :: ∀ env state input output
-- -- |   => Show state
-- -- |    . Saga' env state input output Unit
-- -- | printState = do
-- -- |   state <- select
-- -- |   liftAff $ Console.log $ show state
-- -- | ```
-- select
--   :: ∀ env state input output a
--    . Saga' env state input output state
-- select = do
--   _ /\ { global: { api } } <- Saga' (lift ask)
--   liftEff api.getState

-- | `localEnv` runs a saga in a modified environment. This allows us to combine
-- | sagas in multiple environments. For example, we could write sagas that
-- | require access to certain values like account information without worrying
-- | about "how" to manually pass those values along.
-- |
-- | #### Example
-- |
-- | ``` purescript
-- | printEnv
-- |   :: ∀ env state input output
-- |   => Show env
-- |    . Saga' env state input output Unit
-- | printEnv = do
-- |   env <- ask
-- |   liftEff $ Console.log $ show env
-- |
-- | saga
-- |   :: ∀ env state input output
-- |    . Saga' env state input output Unit
-- | saga = do
-- |   localEnv (const "Hello") printEnv
-- |   localEnv (const "World!") printEnv
-- |
-- | -- >> Hello
-- | -- >> World!
-- | ```
localEnv
  :: ∀ env env2 state input output a
   . (env -> env2)
  -> Saga' env2 state input output a
  -> Saga' env state input output a
localEnv f =
  withReaderT (\x -> x { env = f x.env })

askEnv
  :: ∀ env state input output a
   . Saga' env state input output env
askEnv =
  map _.env ask

-- -- | `fork` puts a saga in the background
-- -- |
-- -- | #### Example
-- -- |
-- -- | ``` purescript
-- -- | helloWorld
-- -- |   :: ∀ env state input output
-- -- |    . Saga' env state input output Unit
-- -- | helloWorld = do
-- -- |   fork $ do
-- -- |     liftAff $ delay $ 10000.0 # Milliseconds
-- -- |     liftAff $ Console.log "World!"
-- -- |   liftEff $ Console.log "Hello"
-- -- |
-- -- | -- >> Hello
-- -- | -- >> World!
-- -- | ```
-- -- |
-- -- | `fork` returns a `SagaTask a`, which can later be joined using `joinTask` or
-- -- | canceled using `cancelTask`.
-- -- |
-- -- | **important**: A saga thread won't finish running until all attached forks have
-- -- | finished running!
-- fork
--   :: ∀ env state input output a eff
--    . Saga' env state input output a
--   -> Saga' env state input output (SagaFiber input a)
-- fork = forkNamed "anonymous"

-- -- | Same as `fork`, but allows setting a custom environment
-- fork'
--   :: ∀ env newEnv state input output a eff
--    . newEnv
--   -> Saga' newEnv state input output a
--   -> Saga' env state input output (SagaFiber input a)
-- fork' = forkNamed' "anonymous"

-- -- | Same as `fork`, but allows setting a name tag
-- forkNamed
--   :: ∀ env state input output a eff
--    . NameTag
--   -> Saga' env state input output a
--   -> Saga' env state input output (SagaFiber input a)
-- forkNamed tag saga = do
--   env <- ask
--   forkNamed' tag env saga

-- -- | Same as `fork'`, but allows setting a name tag
-- forkNamed'
--   :: ∀ env newEnv state input output a eff
--    . String
--   -> newEnv
--   -> Saga' newEnv state input output a
--   -> Saga' env state input output (SagaFiber input a)
-- forkNamed' tag env saga = do
--   _ /\ thread <- Saga' (lift ask)
--   liftIO $ _fork false tag id (const $ pure unit) thread env saga

-- -- | Fork a saga off the current thread.
-- -- We must be sure to safely acquire a new fibre and advertise it to the thread
-- -- for management. We spawn a completely detached `Aff` computation in order not
-- -- be directly affected by cancelation handling, but instead to rely on the
-- -- containing thread to clean this up.
-- _fork
--   :: ∀ env state input input' output a eff
--    . KeepAlive                         -- ^ keep running even with no input
--   -> Label                             -- ^ a name tag
--   -> (input -> input')                 -- ^ convert upstream values
--   -> (Emitter input' -> IO Unit)       -- ^ inject additional values
--   -> ThreadContext state input output  -- ^ the thread we're forking off from
--   -> env                               -- ^ the environment for sagas
--   -> Saga' env state input' output a   -- ^ the saga to evaluate
--   -> IO (SagaFiber input a)
-- _fork keepAlive tag convert inject thread env (Saga' saga) = do
--   fiberId <- nextId thread.global.idSupply

--   let tag' = thread.tag <> ">" <> tag <> " (" <> show fiberId <> ")"
--       log :: String -> IO Unit
--       log msg = debugA $ "fork (" <> tag' <> "): " <> msg

--   liftAff $ unsafeCoerceAff $ do
--     generalBracket
--       (do
--         channel   <- unsafeCoerceAff $ P.spawn P.realTime
--         channel_1 <- unsafeCoerceAff $ P.spawn P.realTime
--         channel_2 <- unsafeCoerceAff $ P.spawn P.realTime

--         { channel, fiberId, fiber: _ }
--           <$> (liftEff $ launchAff $
--                 generalBracket
--                   (do
--                     completionV <- makeEmptyVar
--                     childThreadCtx <- runIO' $ newThreadContext thread.global tag'
--                     channelPipingFiber <- liftEff $ launchAff $ supervise $ do
--                       P.runEffectRec $
--                         P.for (P.fromInput channel) \v ->
--                           liftAff $ do
--                             void $ forkAff $ apathize $ P.send (convert v) channel_1
--                             void $ forkAff $ apathize $ P.send (convert v) channel_2

--                    -- TODO: we should supervise the `P.send` forks, but doing so
--                    --       appears to block indefinitely. Might be related to
--                    --       slamdata/purescript-aff#...
--                    -- TODO: change the api to allow users to temrinate a channel
--                    --       by sending a sentinel: Emit v = Value v | End
--                     userChannelPipingFiber <- liftEff $ launchAff $
--                       bracket
--                         makeEmptyVar
--                         (killVar _COMPLETED_SENTINEL)
--                         \endV -> do
--                           unsafeCoerceAff $ runIO' $ inject \v -> do
--                             liftAff $ do
--                               void $ forkAff $ apathize $ P.send v channel_1
--                               void $ forkAff $ apathize $ P.send v channel_2
--                           takeVar endV

--                     childThreadFiber <- liftEff $ launchAff $ do
--                       debugA $ tag' <> ": _fork: spawning child thread"
--                       runIO' $
--                         runThread (P.input channel_2) childThreadCtx (Just completionV)
--                       debugA $ tag' <> ": _fork: child thread finished"
--                     pure { completionV, childThreadFiber, childThreadCtx, channelPipingFiber, userChannelPipingFiber }
--                   )
--                   { completed: const \{ completionV, childThreadFiber,  channelPipingFiber, userChannelPipingFiber } -> do
--                       debugA $ tag' <> ": _fork: completed: killing child thread..."
--                       killFiber _COMPLETED_SENTINEL childThreadFiber
--                       debugA $ tag' <> ": _fork: completed: killing completionV..."
--                       killVar   _COMPLETED_SENTINEL completionV
--                       debugA $ tag' <> ": _fork: completed: killing channel piping fiber..."
--                       killFiber _COMPLETED_SENTINEL channelPipingFiber
--                       debugA $ tag' <> ": _fork: completed: killing user channel piping fiber..."
--                       killFiber _COMPLETED_SENTINEL userChannelPipingFiber
--                       debugA $ tag' <> ": _fork: completed: sealing channel..."
--                       P.kill _COMPLETED_SENTINEL channel
--                       P.kill _COMPLETED_SENTINEL channel_1
--                       P.kill _COMPLETED_SENTINEL channel_2
--                       debugA $ tag' <> ": _fork: completed: complete"
--                   , failed: \e ({ completionV, childThreadFiber, channelPipingFiber, userChannelPipingFiber }) -> do
--                       debugA $ tag' <> ": _fork: failed: killing child thread fiber..."
--                       killFiber e childThreadFiber
--                       debugA $ tag' <> ": _fork: failed: killing channel piping fiber..."
--                       killFiber e channelPipingFiber
--                       debugA $ tag' <> ": _fork: failed: killing user channel piping fiber..."
--                       killFiber e userChannelPipingFiber
--                       debugA $ tag' <> ": _fork: failed: killing completionV..."
--                       killVar   e completionV
--                       debugA $ tag' <> ": _fork: failed: complete"
--                       P.kill e channel
--                       P.kill e channel_1
--                       P.kill e channel_2
--                   , killed: \e ({ completionV, childThreadFiber, channelPipingFiber, userChannelPipingFiber }) -> do
--                       debugA $ tag' <> ": _fork: killed: killing child thread fiber..."
--                       killFiber e childThreadFiber
--                       debugA $ tag' <> ": _fork: killed: killing channel piping fiber..."
--                       killFiber e channelPipingFiber
--                       debugA $ tag' <> ": _fork: killed: killing user channel piping fiber..."
--                       killFiber e userChannelPipingFiber
--                       debugA $ tag' <> ": _fork: killed: killing completionV..."
--                       killVar   e completionV
--                       debugA $ tag' <> ": _fork: killed: complete"
--                       P.kill e channel
--                       P.kill e channel_1
--                       P.kill e channel_2
--                   }
--                   \{ completionV, childThreadFiber, childThreadCtx } -> do
--                     debugA $ tag' <> ": _fork: evaluating saga..."
--                     runIO' $
--                       flip runReaderT (env /\ childThreadCtx) $ do
--                         P.runEffectRec $
--                           P.for (
--                             P.fromInput' (P.input channel_1) >-> do
--                               saga >>= \val -> do
--                                 liftAff $ do
--                                   debugA $ tag' <> ": _fork: signaling completion"
--                                   putVar val completionV
--                                   debugA $ tag' <> ": _fork: signaled completion"
--                           ) \action -> do
--                             void $
--                               liftEff $
--                                 unsafeCoerceEff $
--                                   thread.global.api.dispatch action

--                     debugA $ tag' <> ": _fork: waiting for child..."
--                     void $ joinFiber childThreadFiber

--                     unless keepAlive $ do
--                       debugA $ tag' <> ": _fork: sealing channels..."
--                       P.seal channel
--                       P.seal channel_1
--                       P.seal channel_2

--                     debugA $ tag' <> ": _fork: waiting for completion..."
--                     result <- takeVar completionV

--                     debugA $ tag' <> ": _fork: completed"
--                     pure result
--               )
--       )
--       { completed: \v _ -> do
--           debugA $ tag' <> ": _fork: fork established"
--       , failed: \e ({ channel, fiber }) -> do
--           debugA $ tag' <> ": _fork: failed: sealing channel..."
--           unsafeCoerceAff $ P.seal channel
--           debugA $ tag' <> ": _fork: failed: killing fiber..."
--           unsafeCoerceAff $ killFiber e fiber
--           debugA $ tag' <> ": _fork: failed: done"
--       , killed: \e ({ channel, fiberId, fiber }) -> do
--           debugA $ tag' <> ": _fork: killed: sealing channel..."
--           unsafeCoerceAff $ P.seal channel
--           debugA $ tag' <> ": _fork: killed: killing fiber..."
--           unsafeCoerceAff $ killFiber e fiber
--           debugA $ tag' <> ": _fork: killed: done"
--       }
--       (\{ channel, fiber, fiberId } ->
--         let sagaFiber :: ∀ x. Fiber _ x -> SagaFiber input x
--             sagaFiber fiber' =
--               SagaFiber
--                 { output: P.output channel
--                 , fiberId
--                 , fiber: fiber'
--                 }
--          in sagaFiber (unsafeCoerceFiberEff fiber) <$
--               let fakeFiber = sagaFiber $ unsafeCoerceFiberEff $ unsafeCoerce fiber
--                in do
--                   -- synchronously register this fiber with the tread.
--                   unsafeCoerceAff $
--                     liftEff $
--                       modifyRef thread.fibersRef $
--                         flip Array.snoc fakeFiber

--                   -- and also push-notify the thread that a new fiber was added.
--                   putVar (Just fakeFiber) thread.newFiberVar

--       )

-- runThread
--   :: ∀ env state input output a
--    . P.Input input
--   -> ThreadContext state input output
--   -> Maybe (AVar a)
--   -> IO Unit
-- runThread input thread completionV =
--   liftAff $
--     generalBracket
--       (do
--           { broadcastFiber: _, supervisionFiber: _ }
--             <$> (liftEff $ launchAff pipeInputToFibers)
--             <*> (liftEff $ launchAff $
--                   let go fibers = do
--                         debugA $ thread.tag <> ": runThread: supervisor: waiting for fibers..."
--                         takeVar thread.newFiberVar >>= case _ of
--                           Nothing -> do
--                             debugA $ thread.tag <> ": runThread: supervisor: awaiting collected fibers..."
--                             for_ fibers joinFiber
--                             debugA $ thread.tag <> ": runThread: supervisor: end"
--                           Just (sagaFiber@SagaFiber { fiber, fiberId }) -> do
--                             debugA $ thread.tag <> ": runThread: supervisor: watching fiber " <> show fiberId
--                             fiber <- forkAff $
--                               unsafeCoerceAff $ do
--                                 debugA $ thread.tag <> ": runThread: supervisor: joining fiber " <> show fiberId
--                                 joinFiber fiber `catchError` \e ->
--                                   unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
--                                           Error.message e == Error.message _CANCELED_SENTINEL) do
--                                     unsafeCoerceAff $ for_ completionV $ killVar e
--                                 unsafeCoerceAff $ liftEff $ unlinkFiber sagaFiber
--                                 debugA $ thread.tag <> ": runThread: supervisor: joined fiber " <> show fiberId
--                             go (fiber A.: fibers)
--                    in go []
--                 )
--       )
--       { completed: \e { broadcastFiber, supervisionFiber } -> do
--           debugA $ thread.tag <> ": runThread: completed: killing broadcast fiber"
--           killFiber _COMPLETED_SENTINEL broadcastFiber
--           debugA $ thread.tag <> ": runThread: completed: killing supervision fiber"
--           killFiber _COMPLETED_SENTINEL supervisionFiber
--           debugA $ thread.tag <> ": runThread: completed: killing remaining fibers"
--           unsafeCoerceAff $ killRemainingFibers _COMPLETED_SENTINEL
--           debugA $ thread.tag <> ": runThread: completed: completed"
--       , failed: \e { broadcastFiber, supervisionFiber } -> do
--           debugA $ thread.tag <> ": runThread: failed: killing broadcast fiber"
--           killFiber e broadcastFiber
--           debugA $ thread.tag <> ": runThread: failed: killing supervision fiber"
--           killFiber e supervisionFiber
--           debugA $ thread.tag <> ": runThread: failed: killing remaining fibers"
--           unsafeCoerceAff $ killRemainingFibers e
--           debugA $ thread.tag <> ": runThread: failed: completed"
--       , killed: \e { broadcastFiber, supervisionFiber } -> do
--           debugA $ thread.tag <> ": runThread: killed: killing broadcast fiber"
--           killFiber e broadcastFiber
--           debugA $ thread.tag <> ": runThread: killed: killing supervision fiber"
--           killFiber e supervisionFiber
--           debugA $ thread.tag <> ": runThread: killed: killing remaining fibers"
--           unsafeCoerceAff $ killRemainingFibers e
--           debugA $ thread.tag <> ": runThread: killed: completed"
--       }
--       \{ supervisionFiber } -> do

--           debugA $ thread.tag <> ": runThread: waiting for completion signal..."
--           void $ for_ completionV readVar `catchError` \e ->
--             unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
--                     Error.message e == Error.message _CANCELED_SENTINEL) do
--               throwError e

--           debugA $ thread.tag <> ": runThread: signaling end of fibers"
--           putVar Nothing thread.newFiberVar
--           debugA $ thread.tag <> ": runThread: signaled end of fibers"

--           debugA $ thread.tag <> ": runThread: waiting for supervision fiber..."
--           joinFiber supervisionFiber `catchError` \e ->
--             unless (Error.message e == Error.message _COMPLETED_SENTINEL ||
--                     Error.message e == Error.message _CANCELED_SENTINEL) do
--               throwError e

--           debugA $ thread.tag <> ": runThread: done"

--   where
--   killRemainingFibers e = do
--     fibers <- unsafeCoerceAff $ liftEff $ readRef thread.fibersRef
--     for_ fibers \(SagaFiber { fiber, fiberId }) -> do
--       debugA $ thread.tag <> ": runThread: killRemainingFibers: killing " <> show fiberId <> " ..."
--       -- Note: Need to start a kill this fiber in a fresh Aff context to avoid
--       --       potentially causing an error while running the finalizer.
--       -- TODO: Spend more time understanding this. What are the implications?
--       -- Refer: https://github.com/slamdata/purescript-aff/blob/master/src/Control/Monad/Aff.js#L502-L505
--       void $ liftEff $ launchAff $ killFiber e fiber
--       debugA $ thread.tag <> ": runThread: killRemainingFibers: killed " <> show fiberId <> " ..."

--   unlinkFiber (SagaFiber { fiberId }) =
--     modifyRef thread.fibersRef $
--       Array.filter \(SagaFiber { fiberId: fiberId' }) ->
--         not $ fiberId == fiberId'

--   pipeInputToFibers =
--     P.runEffectRec $ P.for (P.fromInput' input) \value -> do
--       fibers <- liftEff $ readRef thread.fibersRef
--       lift $ for_ fibers \(SagaFiber { output }) -> do
--         debugA $ thread.tag <> ": runThread: sending value along"
--         void $ forkAff $ apathize $ P.send' value output

-- newThreadContext
--   :: ∀ state input action
--    . GlobalState state action
--   -> Label
--   -> IO (ThreadContext state input action)
-- newThreadContext global tag =
--   { global, tag, fibersRef: _, newFiberVar: _ }
--     <$> (liftEff $ newRef [])
--     <*> (liftAff makeEmptyVar)

-- -- | Simplified `Saga'` alias where the input and output is the same.
-- type Saga env state action a = Saga' env state action action a

-- -- | The `Saga` monad is an opinionated, closed monad with a range of
-- -- | functionality.
-- -- |
-- -- |                read-only environment, accessible via `MonadAsk` instance
-- -- |                /   your state container type (reducer)
-- -- |                |    /    the type this saga consumes (i.e. actions)
-- -- |                |    |     /    the type of output this saga produces (i.e. actions)
-- -- |                |    |     |     /    the return value of this Saga
-- -- |                |    |     |     |     /
-- -- | newtype Saga' env state input output a = ...
-- -- |
-- -- | ### The `env` parameter
-- -- |
-- -- | The `env` parameter gives us access to a read-only environment, accessible via
-- -- | `MonadAsk` instance. Forked computations have the opportunity to change this
-- -- | environment for the execution of the fork without affecting the current thread's
-- -- | `env`.
-- -- |
-- -- | ``` purescript
-- -- | type MyConfig = { apiUrl :: String }
-- -- |
-- -- | logApiUrl :: ∀ state input output. Saga' MyConfig state input output Unit
-- -- | logApiUrl = void do
-- -- |     { apiUrl } <- ask
-- -- |     liftIO $ Console.log apiUrl
-- -- | ```
-- -- |
-- -- | ### The `state` parameter
-- -- |
-- -- | The `state` parameter gives us read access to the current application state via
-- -- | the `select` combinator. This value may change over time.
-- -- |
-- -- | ``` purescript
-- -- | type MyState = { currentUser :: String }
-- -- |
-- -- | logUser :: ∀ env input output. Saga' env MyState input output Unit
-- -- | logUser = void do
-- -- |     { currentUser } <- select
-- -- |     liftIO $ Console.log currentUser
-- -- | ```
-- -- |
-- -- | ### The `input` parameter
-- -- |
-- -- | The `input` parameter denotes the type of input this saga consumes. This in
-- -- | combination with the `output` parameter exposes sagas for what they naturally
-- -- | are: pipes consuming `input` and producing `output`. Typically this input type
-- -- | would correspond to your application's actions type.
-- -- |
-- -- | ``` purescript
-- -- | data MyAction
-- -- |   = LoginRequest Username Password
-- -- |   | LogoutRequest
-- -- |
-- -- | loginFlow :: ∀ env state output. Saga' env state MyAction MyAction Unit
-- -- | loginFlow = forever do
-- -- |   take case _ of
-- -- |     LoginRequest user pw -> do
-- -- |       ...
-- -- |     _ -> Nothing -- ignore other actions
-- -- | ```
-- -- |
-- -- | ### The `output` parameter
-- -- |
-- -- | The `output` parameter denotes the type of output this saga produces. Typically
-- -- | this input type would correspond to your application's actions type. The
-- -- | `output` sagas produce is fed back into redux cycle by dispatching it to the
-- -- | store.
-- -- |
-- -- | ``` purescript
-- -- | data MyAction
-- -- |   = LoginRequest Username Password
-- -- |   | LogoutSuccess Username
-- -- |   | LogoutFailure Error
-- -- |   | LogoutRequest
-- -- |
-- -- | loginFlow :: ∀ env state. Saga' env state MyAction MyAction Unit
-- -- | loginFlow = forever do
-- -- |   take case _ of
-- -- |     LoginRequest user pw -> do
-- -- |       liftAff (attempt {- some I/O -}) >>= case _ of
-- -- |         Left err -> put $ LoginFailure err
-- -- |         Right v  -> put $ LoginSuccess user
-- -- |     _ -> Nothing -- ignore other actions
-- -- | ```
-- -- |
-- -- | ### The `a` parameter
-- -- |
-- -- | The `a` parameter allows every saga to return a value, making it composable.
-- -- | Here's an example of a contrived combinator
-- -- |
-- -- | ``` purescript
-- -- | type MyAppConf = { apiUrl :: String }
-- -- | type Account = { id :: String, email :: String }
-- -- |
-- -- | getAccount
-- -- |   :: ∀ state input output
-- -- |     . String
-- -- |   -> Saga' MyAppConf state input output Account
-- -- | getAccount id = do
-- -- |   { apiUrl } <- ask
-- -- |   liftAff (API.getAccounts apiUrl)
-- -- |
-- -- | -- later ...
-- -- |
-- -- | saga
-- -- |   :: ∀ state input output
-- -- |    . Saga' MyAppConf state input output Unit
-- -- | saga = do
-- -- |   account <- getAccount "123-dfa-123"
-- -- |   liftEff $ Console.log $ show account.email
-- -- | ```

-- newtype Saga' env state input output a =
--   Sata' (ReaderT (

-- newtype Saga' env state input output a
--   = Saga' (
--       P.Pipe
--         input
--         output
--         (ReaderT (env /\ (ThreadContext state input output)) IO)
--         a
--     )

-- derive instance newtypeSaga' :: Newtype (Saga' env state input action a) _
-- derive newtype instance applicativeSaga :: Applicative (Saga' env state input action)
-- derive newtype instance functorSaga :: Functor (Saga' env state input action)
-- derive newtype instance applySaga :: Apply (Saga' env state input action)
-- derive newtype instance bindSaga :: Bind (Saga' env state input action)
-- derive newtype instance monadSaga :: Monad (Saga' env state input action)
-- derive newtype instance monadRecSaga :: MonadRec (Saga' env state input action)
-- derive newtype instance monadThrowSaga :: MonadThrow Error (Saga' env state input action)
-- derive newtype instance monadErrorSaga :: MonadError Error (Saga' env state input action)

-- -- | Races two sagas in parallel
-- -- | The losing saga will be canceled via `cancelTask`
-- instance altSaga :: Alt (Saga' env state input action) where
--   alt s1 s2 = do
--     t1@(SagaFiber { fiber: f1 }) <- forkNamed "L" s1
--     t2@(SagaFiber { fiber: f2 }) <- forkNamed "R" s2
--     result <- liftAff do
--       sequential $
--         parallel (Left  <$> joinFiber f1) <|>
--         parallel (Right <$> joinFiber f2)
--     case result of
--       Left  v -> v <$ cancelTask t2
--       Right v -> v <$ cancelTask t1

-- instance monadAskSaga :: MonadAsk env (Saga' env state input action) where
--   ask = fst <$> Saga' (lift ask)

-- instance monadReaderSaga :: MonadReader env (Saga' env state input action) where
--   local f saga = do
--     env <- ask
--     joinTask =<< fork' (f env) saga

-- instance monadIOSaga :: MonadIO (Saga' env state input action) where
--   liftIO action = Saga' $ liftIO action

-- instance monadEffSaga :: MonadEff eff (Saga' env state input action) where
--   liftEff action = Saga' $ liftEff action

-- instance monadAffSaga :: MonadAff eff (Saga' env state input action) where
--   liftAff action = Saga' $ liftAff action

-- type SagaPipe env state input action a
--   = P.Pipe
--       input
--       action
--       (ReaderT (env /\ (ThreadContext state input action)) IO)
--       a

-- type GlobalState state action
--   = { idSupply :: IdSupply
--     , api :: Redux.MiddlewareAPI (infinity :: INFINITY) state action
--     }

-- -- | A `SagaFiber` is a single computation.
-- newtype SagaFiber input a
--   = SagaFiber
--       { fiberId :: Int
--       , output :: P.Output input
--       , fiber :: Fiber (infinity :: INFINITY) a
--       }

-- -- | A `ThreadContext` is a collection of saga fibers.
-- type ThreadContext state input action
--   = { global :: GlobalState state action
--     , tag :: String
--     , fibersRef :: Ref (Array (SagaFiber input Unit))
--     , newFiberVar :: AVar (Maybe (SagaFiber input Unit))
--     }

-- type Channel a state action
--   = { output :: P.Output a
--     , input :: P.Input a
--     }

-- newtype IdSupply = IdSupply (Ref Int)

-- newIdSupply :: IO IdSupply
-- newIdSupply = IdSupply <$> liftEff (newRef 0)

-- nextId :: IdSupply -> IO Int
-- nextId (IdSupply ref) = liftEff $ modifyRef' ref \value -> { state: value + 1, value }


type Saga' env state i o =
  ReaderT
    { env :: env
    , inputBus :: Bus.BusRW i
    , api :: Redux.MiddlewareAPI state o
    } Aff

runSaga
  :: ∀ env state i o a
   . Saga' env state i o a
  -> env
  -> Redux.MiddlewareAPI state o
  -> Bus.BusRW i
  -> Aff a
runSaga action env api inputBus =
  runReaderT action { env, api, inputBus }

{-| Install and initialize the saga middleware.
  |
  | We need the `dispatch` function to run the saga, but we need the saga to get
  | the `dispatch` function. To break this cycle, we run an `unsafePerformEff`
  | and capture the `dispatch` function immediately.
  |
  | Since this has to integrate with react-redux, there's no way to avoid this
  | and "redux-saga" does the equivalent hack in it's codebase.
-}
sagaMiddleware
  :: ∀ action state
   . Saga' Unit state action action Unit
  -> Redux.Middleware state action _ _
sagaMiddleware saga = wrap $ \api ->
  let
    emitAction =
      unsafePerformEffect do
        inputBus <- Bus.make
        launchAff_ do
          runSaga saga unit api inputBus
        pure \action -> do
          launchAff_ $
            void $ try $
              Bus.write action inputBus
   in
    \next action ->
      void do
        emitAction action
        next action
