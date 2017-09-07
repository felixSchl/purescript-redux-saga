module Redux.Saga (
    sagaMiddleware
  , Saga
  , Saga'
  , SagaPipe
  , SagaVolatileState
  , takeEvery
  , take
  , fork
  , put
  , select
  , joinTask
  , channel
  , inChannel
  , emit
  ) where

import Prelude

import Data.Maybe (Maybe(..))
import Data.Array as Array
import Data.Tuple.Nested ((/\))
import Data.Time.Duration (Milliseconds(..))
import Data.Foldable (for_)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Aff (forkAff, Aff, Canceler, finally, delay, launchAff)
import Control.Monad.Aff.AVar (AVar, AVAR, takeVar, putVar, makeVar, peekVar)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Ref (Ref, REF, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Console as Console
import Control.Monad.Eff.Exception (EXCEPTION)
import Control.Monad.Eff.Console (CONSOLE)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.Morph (hoist)
import React.Redux (ReduxEffect, REDUX)
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

import Pipes.Aff as P
import Pipes.Prelude as P
import Pipes ((>->))
import Pipes.Core as P
import Pipes as P

type Channel eff a action state
  = { volatile :: SagaVolatileState (ref :: REF, avar :: AVAR | eff) a action state
    , output :: P.Output (ref :: REF, avar :: AVAR | eff) a
    , input :: P.Input (ref :: REF, avar :: AVAR | eff) a
    }

emit
  :: ∀ eff a action state
   . a
  -> Channel eff a action state
  -> Aff (ref :: REF, avar :: AVAR | eff) Unit
emit a { output } = void $ P.send output a

channel
  :: ∀ eff input action state a r
   . Saga' (ref :: REF, avar :: AVAR | eff) input action state (Channel eff a action state)
channel = Saga' $ unsafeCoerceSagaPipeEff do

  { api }           <- unsafeCoerceSagaPipeEff $ lift ask
  { output, input } <- liftAff $ P.spawn P.unbounded
  idRef             <- liftEff $ newRef 0
  threadsRef        <- liftEff $ newRef []

  _ <- liftAff $ forkAff do
    -- first exhaust the input pipe
    P.runEffectRec $ P.for (P.fromInput input) \action -> do
      threads <- liftEff $ readRef threadsRef
      lift $ for_ threads \{ output } -> P.send output action

    -- then wait for all threads to complete running
    threads <- liftEff $ readRef threadsRef
    for_ threads (peekVar <<< _.completionVar)

  pure { output, input, volatile: { threadsRef, idRef, api } }

inChannel
  :: ∀ a input action state eff
   . Channel eff a action state
  -> Saga' (ref :: REF, avar :: AVAR | eff) a action state Unit
  -> Saga' (ref :: REF, avar :: AVAR | eff) input action state Unit
inChannel { volatile } saga = void $ liftAff $ attachSaga volatile saga

takeEvery
  :: ∀ input action state eff eff2
   . (input -> Maybe (Saga' eff input action state Unit))
  -> Saga' eff2 input action state SagaTask
takeEvery f = fork $ loop
  where
  loop = do
    take f
    loop

take
  :: ∀ input action state eff
   . (input -> Maybe (Saga' eff input action state Unit))
  -> Saga' eff input action state Unit
take f = Saga' go
  where
  go = map f P.await >>= case _ of
    Just (Saga' saga) -> saga
    Nothing           -> go

put
  :: ∀ input action a state eff
   . action
  -> Saga' eff input action state Unit
put action = Saga' $ P.yield action

joinTask
  :: ∀ eff input action state. SagaTask
  -> Saga' eff input action state Unit
joinTask v = Saga' $ lift $ lift $ takeVar v

fork
  :: ∀ eff eff2 input action state
   . Saga' eff input action state Unit
  -> Saga' eff2 input action state SagaTask
fork saga = Saga' do
  lift do
    state <- ask
    lift $ attachSaga state saga

select
  :: ∀ eff input action state
   . SagaPipe eff input action state state
select = do
  { api } <- lift ask
  lift $ liftEff $ unsafeCoerceEff api.getState

attachSaga
  :: ∀ eff eff2 input action state
   . SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state
  -> Saga' eff2 input action state Unit
  -> Aff (ref :: REF, avar :: AVAR | eff) SagaTask
attachSaga { threadsRef, idRef, api } (Saga' saga) = do
  id <- liftEff $ modifyRef' idRef \value -> { state: value + 1, value }
  { output, input } <- P.spawn P.unbounded
  completionVar <- makeVar
  completionVar <$ do
    void $ forkAff do
      finally do
        (liftEff $ modifyRef threadsRef (Array.filter ((_ /= id) <<< _.id))) do
        flip runReaderT { api, threadsRef, idRef }
          $ P.runEffectRec
          $ P.for (P.fromInput input >-> unsafeCoerceSagaPipeEff saga) \action -> do
              lift do
                liftAff $ delay $ 0.0 # Milliseconds
                liftEff $ unsafeCoerceEff $ api.dispatch action
        putVar completionVar unit
    liftEff $ modifyRef threadsRef (_ `Array.snoc` { id, output, completionVar })

evaluateSaga
  :: ∀ eff eff2 action state
   . Redux.MiddlewareAPI (avar :: AVAR, ref :: REF | eff) action state Unit
  -> P.Input (avar :: AVAR, ref :: REF | eff) action
  -> Saga' eff2 action action state Unit
  -> Aff (avar :: AVAR, ref :: REF | eff) Unit
evaluateSaga api input saga = do
  idRef      <- liftEff $ newRef 0
  threadsRef <- liftEff $ newRef []
  _          <- attachSaga { idRef, threadsRef, api } saga

  -- first exhaust the input pipe
  P.runEffectRec $ P.for (P.fromInput input) \action -> do
    threads <- liftEff $ readRef threadsRef
    lift $ for_ threads \{ output } -> P.send output action

  -- then wait for all threads to complete running
  threads <- liftEff $ readRef threadsRef
  for_ threads (peekVar <<< _.completionVar)

{-
  The type of a saga.
  It yields and produces actions.
 -}
type Saga eff action state a = Saga' eff action action state a

newtype Saga' eff input action state a
  = Saga' (SagaPipe (ref :: REF, avar :: AVAR | eff) input action state a)

unSaga
  :: ∀ eff input action state a
   . Saga' eff input action state a
  -> SagaPipe (ref :: REF, avar :: AVAR | eff) input action state a
unSaga (Saga' saga) = saga

instance applicativeSaga :: Applicative (Saga' eff input action state) where
  pure a = Saga' $ pure a

instance functorSaga :: Functor (Saga' eff input action state) where
  map f (Saga' x) = Saga' $ map f x

instance applySaga :: Apply (Saga' eff input action state) where
  apply (Saga' f) (Saga' v) = Saga' $ apply f v

instance bindSaga :: Bind (Saga' eff input action state) where
  bind (Saga' v) f = Saga' $ v >>= \v -> unSaga (f v)

instance monadSaga :: Monad (Saga' eff input action state)

instance monadEffSaga :: MonadEff eff (Saga' eff input action state) where
  liftEff eff = Saga' $ liftEff $ unsafeCoerceEff eff

instance monadAffSaga :: MonadAff eff (Saga' eff input action state) where
  liftAff aff = Saga' $ lift $ lift $ unsafeCoerceAff aff

type SagaTask = AVar Unit

type SagaVolatileState eff input action state
  = { threadsRef :: Ref (Array { id :: Int
                               , output :: P.Output eff input
                               , completionVar :: AVar Unit
                               })
    , idRef :: Ref Int
    , api :: Redux.MiddlewareAPI eff action state Unit
    }

type SagaPipe eff input action state a
  = P.Pipe
      input
      action
      (ReaderT  (SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state)
                (Aff (ref :: REF, avar :: AVAR | eff)))
      a

unsafeCoerceSagaPipeEff
  :: ∀ eff eff2 input action state a
   . SagaPipe eff input action state a
  -> SagaPipe eff2 input action state a
unsafeCoerceSagaPipeEff = unsafeCoerce

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
   . Saga' _ action action state Unit
  -> Redux.Middleware _ action state Unit
sagaMiddleware saga api =
  let emitAction
        = unsafePerformEff do
            refOutput <- newRef Nothing
            refCallbacks  <- newRef []
            _ <- launchAff do
              { input, output } <- P.spawn P.unbounded
              callbacks <- liftEff $ modifyRef' refCallbacks \value -> { state: [], value }
              for_ callbacks (_ $ output)
              liftEff $ modifyRef refOutput (const $ Just output)
              evaluateSaga api input saga
            pure \action -> void do
              readRef refOutput >>= case _ of
                Just output -> void $ launchAff $ P.send output action
                Nothing -> void $ modifyRef refCallbacks
                                            (_ `Array.snoc` \output ->
                                              void $ P.send output action)
   in \next action -> void $ (emitAction action) *> next action
