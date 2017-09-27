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

import Debug.Trace
import Prelude

import Control.Alt ((<|>))
import Control.Monad.Aff (forkAff, Aff, finally, delay, launchAff, attempt)
import Control.Monad.Aff.AVar (AVar, AVAR, takeVar, putVar, makeVar, peekVar)
import Control.Monad.Aff.Class (class MonadAff, liftAff)
import Control.Monad.Aff.Unsafe (unsafeCoerceAff)
import Control.Monad.Eff.Class (class MonadEff, liftEff)
import Control.Monad.Eff.Exception (EXCEPTION, error, Error, throwException, stack)
import Control.Monad.Eff.Ref (Ref, REF, newRef, readRef, modifyRef, modifyRef')
import Control.Monad.Eff.Unsafe (unsafeCoerceEff, unsafePerformEff)
import Control.Monad.Error.Class (class MonadError, class MonadThrow, throwError, catchError)
import Control.Monad.Reader (ask)
import Control.Monad.Reader.Trans (runReaderT, ReaderT)
import Control.Monad.Rec.Class (class MonadRec)
import Control.Monad.Trans.Class (lift)
import Control.Parallel (parallel, sequential)
import Data.Array as Array
import Data.Either (Either(Right, Left))
import Data.Foldable (for_)
import Data.Maybe (Maybe(..), maybe, fromMaybe)
import Data.Newtype (class Newtype)
import Data.Time.Duration (Milliseconds(..))
import Pipes ((>->))
import Pipes as P
import Pipes.Aff as P
import Pipes.Core as P
import Pipes.Prelude as P
import React.Redux as Redux
import Unsafe.Coerce (unsafeCoerce)

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
  :: ∀ eff input action state a
   . Saga' (ref :: REF, avar :: AVAR | eff) input action state (Channel eff a action state)
channel = Saga' $ unsafeCoerceSagaPipeEff do
    { api, failureVar } <- unsafeCoerceSagaPipeEff $ lift ask
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
   . Channel eff a action state
  -> Saga' (ref :: REF, avar :: AVAR | eff) a action state Unit
  -> Saga' (ref :: REF, avar :: AVAR | eff) input action state Unit
inChannel { volatile } saga = void $ liftAff $ attachSaga volatile saga Nothing

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
  :: ∀ input action state eff
   . action
  -> Saga' eff input action state Unit
put action = Saga' $ P.yield action

joinTask
  :: ∀ eff input action state. SagaTask
  -> Saga' eff input action state (Maybe Error)
joinTask v = Saga' $ lift $ lift $ takeVar v

fork
  :: ∀ eff eff2 input action state
   . Saga' eff input action state Unit
  -> Saga' eff2 input action state SagaTask
fork saga = Saga' do
  lift do
    state <- ask
    lift $ attachSaga state saga Nothing

select
  :: ∀ eff input action state
   . Saga' eff input action state state
select = Saga' do
  { api } <- lift ask
  lift $ liftEff $ unsafeCoerceEff api.getState

attachSaga
  :: ∀ eff eff2 input action state
   . SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state
  -> Saga' eff2 input action state Unit
  -> Maybe String
  -> Aff (ref :: REF, avar :: AVAR | eff) SagaTask
attachSaga { threadsRef, idRef, failureVar, api } (Saga' saga) mTag = do
  let tag = fromMaybe "anonymous" mTag
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
              let e' = error
                        $ "Saga " <> show tag
                          <> " terminated due to error"
                          <> maybe "" (", stack trace follows:\n" <> _) (stack e)
              putVar completionVar $ Just e'
              putVar failureVar e'
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
                    (Just "root")

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
      throwError err
    _ -> pure unit

{-
  The type of a saga.
  It yields and produces actions.
 -}
type Saga eff action state a = Saga' eff action action state a

newtype Saga' eff input action state a
  = Saga' (
      P.Pipe
        input
        action
        (ReaderT  (SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state)
                  (Aff (ref :: REF, avar :: AVAR | eff)))
        a
    )

type SagaPipe eff input action state a
  = P.Pipe
      input
      action
      (ReaderT  (SagaVolatileState (ref :: REF, avar :: AVAR | eff) input action state)
                (Aff (ref :: REF, avar :: AVAR | eff)))
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

derive instance newtypeSaga' :: Newtype (Saga' eff input action state a) _

derive newtype instance applicativeSaga :: Applicative (Saga' eff input action state)
derive newtype instance functorSaga :: Functor (Saga' eff input action state)
derive newtype instance applySaga :: Apply (Saga' eff input action state)
derive newtype instance bindSaga :: Bind (Saga' eff input action state)
derive newtype instance monadSaga :: Monad (Saga' eff input action state)
derive newtype instance monadRecSaga :: MonadRec (Saga' eff input action state)
derive newtype instance monadThrowSaga :: MonadThrow Error (Saga' eff input action state)
derive newtype instance monadErrorSaga :: MonadError Error (Saga' eff input action state)

instance monadEffSaga :: MonadEff eff (Saga' eff input action state) where
  liftEff eff = Saga' $ liftEff $ unsafeCoerceEff eff

instance monadAffSaga :: MonadAff eff (Saga' eff input action state) where
  liftAff aff = Saga' $ lift $ lift $ unsafeCoerceAff aff


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
              { input, output } <- P.spawn P.new
              callbacks <- liftEff $ modifyRef' refCallbacks \value -> { state: [], value }
              for_ callbacks (_ $ output)
              liftEff $ modifyRef refOutput (const $ Just output)
              liftAff $ delay (0.0 # Milliseconds)
              flip catchError
                (\e ->
                  let msg = maybe "" (", stack trace follows:\n" <> _) $ stack e
                   in throwError $ error $ "Saga terminated due to error" <> msg)
                $ evaluateSaga api input saga
            pure \action -> void do
              readRef refOutput >>= case _ of
                Just output -> void $ launchAff $ P.send output action
                Nothing -> void $ modifyRef refCallbacks
                                            (_ `Array.snoc` \output ->
                                              void $ P.send output action)
   in \next action -> void $ (emitAction action) *> next action
