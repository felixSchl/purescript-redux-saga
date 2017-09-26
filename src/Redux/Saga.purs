module Redux.Saga (
    sagaMiddleware
  , Saga
  , Saga'
  , SagaPipe
  , SagaVolatileState
  , SagaTask
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

import Data.Newtype (class Newtype)
import Data.Maybe (Maybe(..))
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Time.Duration (Milliseconds(..))
import Data.Foldable (for_)
import Control.Alt ((<|>))
import Control.Parallel (parallel, sequential)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Aff (forkAff, Aff, finally, delay, launchAff, attempt)
import Control.Monad.Aff.AVar (AVar, AVAR, takeVar, putVar, makeVar, peekVar)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Rec.Class (class MonadRec, forever)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Ref (Ref, REF, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Exception (EXCEPTION, Error, throwException)
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
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

_ask :: Saga' eff input action state m _
_ask = lift ask

channel
  :: ∀ eff input action state m a
   . Monad m
  => MonadAff (ref :: REF, avar :: AVAR | eff) m
  => Saga' (ref :: REF, avar :: AVAR | eff) input action state m (Channel eff a action state)
channel = Saga' $ unsafeCoerceSagaPipeEff do
    { api, failureVar } <- _ask
    { output, input }   <- liftAff $ P.spawn P.unbounded
    idRef               <- liftEff $ newRef 0
    threadsRef          <- liftEff $ newRef []
    completionVar       <- liftAff $ makeVar

    _ <- liftAff $ forkAff do
      -- first exhaust the input pipe
      P.runEffectRec $ P.for (P.fromInput input) \action -> do
        threads <- liftEff $ readRef threadsRef
        lift $ for_ threads \{ output: output' } -> P.send output' action

      -- then wait for all threads to complete running
      threads <- liftEff $ readRef threadsRef
      for_ threads (peekVar <<< _.completionVar)

      putVar completionVar unit

    pure { output
         , input
         , volatile: { threadsRef
                     , idRef
                     , api
                     , failureVar
                     } }

inChannel
  :: ∀ a input action state eff
   . Monad m
  => Channel eff a action state
  -> Saga' (ref :: REF, avar :: AVAR | eff) a action state m Unit
  -> Saga' (ref :: REF, avar :: AVAR | eff) input action state m Unit
inChannel { volatile } saga = void $ liftAff $ attachSaga volatile saga

take
  :: ∀ input action state m eff
   . Monad m
  => (input -> Maybe (Saga' eff input action state m Unit))
  -> Saga' eff input action state m Unit
take f = Saga' go
  where
  go = map f P.await >>= case _ of
    Just (Saga' saga) -> saga
    Nothing           -> go

put
  :: ∀ input action state m eff
   . Monad m
  => action
  -> Saga' eff input action state m Unit
put action = Saga' $ P.yield action

joinTask
  :: ∀ eff input action state m
   . MonadAff (avar :: AVAR | eff) m
  => SagaTask
  -> Saga' eff input action state m (Maybe Error)
joinTask v = Saga' $ liftAff $ takeVar v

fork
  :: ∀ eff eff2 input action state
   . Saga' eff input action state Unit
  -> Saga' eff2 input action state SagaTask
fork saga = Saga' do
  lift do
    state <- ask
    lift $ attachSaga state saga

select
  :: ∀ eff input action state m
   . MonadEff eff m
  => Saga' eff input action state m state
select = Saga' do
  { api } <- lift ask
  lift $ liftEff $ unsafeCoerceEff api.getState

attachSaga
  :: ∀ eff eff2 input action state m
   . MonadAff eff2 m
  => SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state
  -> Saga' eff2 input action state m Unit
  -> Aff (ref :: REF, avar :: AVAR | eff) SagaTask
attachSaga { threadsRef, idRef, failureVar, api } (Saga' saga) = do
  id <- liftEff $ modifyRef' idRef \value -> { state: value + 1, value }
  { output, input } <- P.spawn P.new
  completionVar <- makeVar
  completionVar <$ do
    void $ forkAff do
      finally do
        (liftEff $ modifyRef threadsRef (Array.filter ((_ /= id) <<< _.id))) do
        do
          result <- attempt do
            flip runReaderT { api, threadsRef, idRef, failureVar }
              $ P.runEffectRec
              $ P.for (P.fromInput input >-> unsafeCoerceSagaPipeEff saga) \action -> do
                  lift do
                    liftAff $ delay $ 0.0 # Milliseconds
                    liftEff $ unsafeCoerceEff $ api.dispatch action
          case result of
            Left e -> do
              putVar completionVar $ Just e
              putVar failureVar e
            Right _ -> do
              putVar completionVar Nothing
    liftEff $ modifyRef threadsRef (_ `Array.snoc` { id, output, completionVar })

evaluateSaga
  :: ∀ eff eff2 action state
   . Redux.MiddlewareAPI (avar :: AVAR, ref :: REF, exception :: EXCEPTION | eff) action state Unit
  -> P.Input (avar :: AVAR, ref :: REF, exception :: EXCEPTION | eff) action
  -> Saga' eff2 action action state Unit
  -> Aff (avar :: AVAR, ref :: REF, exception :: EXCEPTION | eff) Unit
evaluateSaga api input saga = do
  idRef         <- liftEff $ newRef 0
  threadsRef    <- liftEff $ newRef []
  failureVar    <- makeVar

  void $ attachSaga { idRef
                    , threadsRef
                    , failureVar
                    , api
                    } saga

  result <- sequential do
    parallel (Just <$> peekVar failureVar) <|> do
      Nothing <$ parallel do
        -- first exhaust the input pipe
        P.runEffectRec $ P.for (P.fromInput input) \action -> do
          threads <- liftEff $ readRef threadsRef
          lift $ for_ threads \{ output } -> P.send output action

        -- then wait for all threads to complete running
        threads <- liftEff $ readRef threadsRef
        for_ threads (peekVar <<< _.completionVar)

  case result of
    Just err -> do
      -- TODO: cancel remaining tasks
      liftEff $ throwException err
    _ -> pure unit

{-
  The type of a saga.
  It yields and produces actions.
 -}
type Saga eff action state m a = Saga' eff action action state m a

newtype Saga' eff input action state m a
  = Saga' (
      P.Pipe
        input
        action
        (ReaderT (SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state) m)
        a
    )

type SagaPipe eff input action state m a
  = P.Pipe
      input
      action
      (ReaderT (SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state) m)
      a

type SagaTask = AVar (Maybe Error)

type SagaVolatileState eff input action state
  = { threadsRef :: Ref (Array { id :: Int
                               , output :: P.Output eff input
                               , completionVar :: SagaTask
                               })
    , failureVar :: AVar Error
    , idRef :: Ref Int
    , api :: Redux.MiddlewareAPI eff action state Unit
    }

derive instance newtypeSaga' :: Newtype (Saga' eff input action state m a) _

 -- XXX: why does purescript want a `Monad m` contraint here?
derive newtype instance functorSaga :: Monad m => Functor (Saga' eff input action state m)
derive newtype instance bindSaga :: Monad m => Bind (Saga' eff input action state m)

derive newtype instance applicativeSaga :: Applicative (Saga' eff input action state m)
derive newtype instance applySaga :: Apply (Saga' eff input action state m)
derive newtype instance monadSaga :: Monad m => Monad (Saga' eff input action state m)
derive newtype instance monadRec :: MonadRec m => MonadRec (Saga' eff input action state m)

instance monadEffSaga :: MonadEff eff m => MonadEff eff (Saga' eff input action state m) where
  liftEff eff = Saga' $ liftEff $ unsafeCoerceEff eff

instance monadAffSaga :: MonadAff eff m => MonadAff eff (Saga' eff input action state m) where
  liftAff aff = Saga' $ liftAff $ unsafeCoerceAff aff

unsafeCoerceSagaPipeEff
  :: ∀ eff eff2 input action state m a
   . MonadAff eff m
  => MonadAff eff2 m
  => SagaPipe eff input action state m a
  -> SagaPipe eff2 input action state m a
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
              { input, output } <- P.spawn P.new
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
