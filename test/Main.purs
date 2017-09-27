module Test.Main where

import Debug.Trace
import Prelude
import Redux.Saga

import Control.Monad.Aff (attempt, delay, forkAff)
import Control.Monad.Aff.AVar (makeVar, takeVar, putVar)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error, try)
import Control.Monad.Eff.Ref (modifyRef', modifyRef, newRef, readRef)
import Control.Monad.Error.Class (throwError)
import Control.Monad.IO (IO, runIO, runIO')
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Rec.Class (forever)
import Control.Safely (replicateM_)
import Data.Array as A
import Data.Either (Either(..))
import Data.Foldable (for_)
import Data.List.Lazy (replicateM)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import React.Redux (ReduxEffect)
import React.Redux as Redux
import Test.Spec (describe, describeOnly, it, itOnly, pending')
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter.Console (consoleReporter)
import Test.Spec.Runner (RunnerEffects, run, run', defaultConfig)

data Action = SearchChanged String
type GlobalState = {}

mkStore
  :: ∀ action state eff
   . Redux.Reducer action state
  -> state
  -> Saga action state Unit
  -> IO (Redux.Store action state)
mkStore reducer initialState saga = liftEff do
  Redux.createStore reducer
                    initialState
                    $ Redux.applyMiddleware [ sagaMiddleware saga ]

withCompletionVar f = do
  completedVar <- liftAff makeVar
  f $ putVar completedVar
  liftAff $ takeVar completedVar

main :: Eff _ Unit
main = run' (defaultConfig { timeout = Just 3000 }) [consoleReporter] do
  describe "sagas" do
    describe "take" do
      it "should run matching action handler" do
        r <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            void $ fork do
              take \i -> pure do
                liftAff $ done i
            put 1
        r `shouldEqual` 1

      it "should ignore non-matching actions" do
        r <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            void $ fork do
              take case _ of
                n | n == 2 -> pure $ liftAff $ done n
                _ -> Nothing
            put 1
            put 2
        r `shouldEqual` 2

      it "should be able to run repeatedly" do
        r <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            ref <- liftEff $ newRef []
            void $ fork do
              replicateM_ 3 do
                take \i -> pure do
                  liftEff $ modifyRef ref (_ `A.snoc` i)
              liftEff (readRef ref) >>= liftIO <<< liftAff <<< done
            put 1
            put 2
            put 3
        r `shouldEqual` [1, 2, 3]

      it "should block the thread" do
        r <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            ref <- liftEff $ newRef []
            void $ liftAff $ forkAff $
              delay (10.0 # Milliseconds) *> done true
            take (const Nothing)
            liftAff $ done false
        r `shouldEqual` true

    describe "error handling" do
      -- TODO: How to actually catch these? or at least test that it's
      -- actually crashing
      pending' "should terminate on errors" do
        void $ withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            liftAff $ void $ throwError $ error "oh no"

      -- TODO: How to actually catch these? or at least test that it's
      -- actually crashing
      pending' "sub-sagas should bubble up errors" do
        void $ withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            void $ fork do
              liftAff $ void $ throwError $ error "oh no"

    describe "put" do
      it "should not overflow the stack" do
        withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            replicateM_ 2000 do
               void $ fork $ put unit
            liftAff $ done unit

    describe "forks" do
      it "should not block" do
        x <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            void $ fork do
              take (const Nothing)
              liftAff $ done false
            liftAff $ done true
        x `shouldEqual` true

      it "should not block in Aff" do
        x <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            void $ fork do
              liftAff $ void $ forever do
                delay $ 0.0 # Milliseconds
              liftAff $ done false
            liftAff $ done true
        x `shouldEqual` true

      it "should be joinable" do
        withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            t <- fork do
              liftAff $ delay $ 100.0 # Milliseconds
            joinTask t
            liftAff $ done unit

      it "should be joinable (2)" do
        n <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            t <- fork do
              take $ const $ pure do
                liftEff $ modifyRef ref (_ + 1)
            put unit
            joinTask t
            liftEff (readRef ref) >>= liftAff <<< done
        n `shouldEqual` 1

      it "should be joinable (3)" do
        n <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            t <- fork do
              replicateM_ 10 do
                take $ const $ pure do
                  liftEff $ modifyRef ref (_ + 1)
            replicateM_ 10 $ put unit
            joinTask t
            liftEff (readRef ref) >>= liftAff <<< done
        n `shouldEqual` 10

      it "should wait for child processes" do
        x <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            task <- fork do
              liftAff do
                delay $ 100.0 # Milliseconds
                done true
            void $ joinTask task
            liftAff $ done false
        x `shouldEqual` true

      it "should wait for nested child processes" do
        x <- withCompletionVar \done -> do
          void $ runIO' $ mkStore (const id) {} do
            task <-fork do
              void $ fork do
                liftAff do
                  delay $ 100.0 # Milliseconds
                  done true
            void $ joinTask task
            liftAff $ done false
        x `shouldEqual` true

      describe "cancellation" do
        it "should be able to cancel forks" do
          x <- withCompletionVar \done -> do
            void $ runIO' $ mkStore (const id) {} do
              task <- fork do
                task' <- fork do
                  liftAff $ void $ forever do
                    delay $ 0.0 # Milliseconds
                  liftAff $ done false
                cancel task'
              joinTask task
              liftAff $ done true
          x `shouldEqual` true

        it "should be able to cancel forks" do
          r <- withCompletionVar \done -> do
            void $ runIO' $ mkStore (const id) {} do
              ref <- liftEff $ newRef []
              task <- fork do
                forever do
                  take \i -> pure do
                    liftEff $ modifyRef ref (_ `A.snoc` i)
              for_ [ 1, 2, 3 ] put
              cancel task
              for_ [ 4, 5, 6, 7, 8, 9 ] put
              liftEff (readRef ref) >>= liftAff <<< done
          r `shouldEqual` [1, 2, 3]
