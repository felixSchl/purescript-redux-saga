module Test.Main where

import Prelude
import Redux.Saga

import Control.Monad.Aff (delay, forkAff)
import Control.Monad.Aff.AVar (makeEmptyVar, takeVar, putVar)
import Control.Monad.Aff.Class (liftAff)
import Control.Monad.Eff (Eff)
import Control.Monad.Eff.Class (liftEff)
import Control.Monad.Eff.Exception (error)
import Control.Monad.Eff.Ref (modifyRef, newRef, readRef)
import Control.Monad.Error.Class (throwError)
import Control.Monad.IO (IO, runIO')
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Rec.Class (forever)
import Control.Safely (replicateM_)
import Data.Array as A
import Data.Foldable (for_)
import Data.Maybe (Maybe(..))
import Data.Time.Duration (Milliseconds(..))
import Debug.Trace (traceAnyA)
import React.Redux as Redux
import Test.Spec (describe, describeOnly, it, itOnly, pending')
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter.Console (consoleReporter)
import Test.Spec.Runner (run', defaultConfig)

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

withCompletionVar :: ∀ a. ((a -> IO Unit) -> IO Unit) -> IO a
withCompletionVar f = do
  completedVar <- liftAff makeEmptyVar
  liftAff $ void $ forkAff do
    runIO' $ f $ liftAff <<< flip putVar completedVar
  liftAff $ takeVar completedVar

main :: Eff _ Unit
main = run' (defaultConfig { timeout = Just 5000 }) [consoleReporter] do
  describe "sagas" do
    describe "take" do
      it "should run matching action handler" do
        r <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              take \i -> pure do
                liftIO $ done i
            put 1
        r `shouldEqual` 1

      it "should ignore non-matching actions" do
        r <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              take \i -> case i of
                n | n == 2 -> pure do
                  liftIO $ done n
                _ -> Nothing
            put 1
            put 2
        r `shouldEqual` 2

      it "should be able to run repeatedly" do
        r <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            ref <- liftEff $ newRef []
            void $ forkNamed "INNER" do
              replicateM_ 3 do
                take \i -> pure do
                  liftEff $ modifyRef ref (_ `A.snoc` i)
              liftEff (readRef ref) >>= liftIO <<< done
            put 1
            put 2
            put 3
            put 4
        r `shouldEqual` [1, 2, 3]

      it "should block the thread" do
        r <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            ref <- liftEff $ newRef []
            void $ liftAff $ forkAff do
              delay $ 10.0 # Milliseconds
              runIO' $ done true
            take (const Nothing)
            liftIO $ done false
        r `shouldEqual` true

    describe "error handling" do
      -- TODO: How to actually catch these? or at least test that it's
      -- actually crashing
      pending' "should terminate on errors" do
        void $ runIO' $ withCompletionVar \_ -> do
          void $ mkStore (const id) {} do
            liftAff $ void $ throwError $ error "oh no"

      -- TODO: How to actually catch these? or at least test that it's
      -- actually crashing
      pending' "sub-sagas should bubble up errors" do
        void $ runIO' $ withCompletionVar \_ -> do
          void $ mkStore (const id) {} do
            void $ fork do
              liftAff $ void $ throwError $ error "oh no"

    describe "put" do
      it "should not overflow the stack" do
        runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            replicateM_ 10000 $ put unit
            liftIO $ done unit

    describe "forks" do
      it "should not block" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              take (const Nothing)
              liftIO $ done false
            liftIO $ done true
        x `shouldEqual` true

      it "should not block in Aff" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              liftAff $ void $ forever do
                delay $ 0.0 # Milliseconds
              liftIO $ done false
            liftIO $ done true
        x `shouldEqual` true

      it "should be joinable" do
        runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            t <- fork do
              liftAff $ delay $ 100.0 # Milliseconds
            joinTask t
            liftIO $ done unit

      it "should be joinable (2)" do
        n <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            t <- fork do
              take $ const $ pure do
                liftEff $ modifyRef ref (_ + 1)
            put unit
            joinTask t
            liftEff (readRef ref) >>= liftIO <<< done
        n `shouldEqual` 1

      it "should be joinable (3)" do
        n <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            ref <- liftEff $ newRef 0
            t <- fork do
              replicateM_ 10 do
                take $ const $ pure do
                  liftEff $ modifyRef ref (_ + 1)
            replicateM_ 10 $ put unit
            joinTask t
            liftEff (readRef ref) >>= liftIO <<< done
        n `shouldEqual` 10

      it "should wait for child processes" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            task <- fork do
              liftAff $ delay $ 100.0 # Milliseconds
              liftIO $ done true
            void $ joinTask task
            liftIO $ done false
        x `shouldEqual` true

      it "should wait for child processes (2)" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              void $ fork do
                take $ const $ pure $ liftIO $ done true
            liftAff $ delay $ 10.0 # Milliseconds
            put unit
        x `shouldEqual` true

      it "should wait for child processes (3)" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            void $ fork do
              void $ fork do
                 void $ forever $ take case _ of
                  5 -> pure $ liftIO $ done true
                  _ -> Nothing
            put 1
            put 2
            put 3
            put 4
            put 5
        x `shouldEqual` true

      it "should wait for nested child processes" do
        x <- runIO' $ withCompletionVar \done -> do
          void $ mkStore (const id) {} do
            task <-fork do
              void $ fork do
                liftAff $ delay $ 100.0 # Milliseconds
                liftIO $ done true
            void $ joinTask task
            liftIO $ done false
        x `shouldEqual` true

      describe "cancellation" do
        it "should be able to cancel forks" do
          x <- runIO' $ withCompletionVar \done -> do
            void $ mkStore (const id) {} do
              task <- fork do
                task' <- fork do
                  liftAff $ void $ forever do
                    delay $ 0.0 # Milliseconds
                  liftIO $ done false
                cancel task'
              joinTask task
              liftIO $ done true
          x `shouldEqual` true

        it "should be able to cancel forks (2)" do
          r <- runIO' $ withCompletionVar \done -> do
            void $ mkStore (const id) {} do
              ref <- liftEff $ newRef []
              task <- fork do
                forever do
                  take \i -> pure do
                    liftEff $ modifyRef ref (_ `A.snoc` i)
              for_ [ 1, 2, 3 ] put

              liftAff $ delay $ 10.0 # Milliseconds
              cancel task

              for_ [ 4, 5, 6, 7, 8, 9 ] put
              liftAff $ delay $ 10.0 # Milliseconds

              liftEff (readRef ref) >>= liftIO <<< done
          r `shouldEqual` [1, 2, 3]

      describe "channels" do
        it "should call emitter block" do
          r <- runIO' $ withCompletionVar \done -> do
            void $ mkStore (const id) {} do
              channel "foo"
                (\emit -> done true)
                (pure unit)
          r `shouldEqual` true

        it "should emit to the saga block" do
          r <- runIO' $ withCompletionVar \done -> do
            void $ mkStore (const id) {} do
              channel "foo"
                (\emit -> emit "foo")
                (take case _ of
                  "foo" -> pure do
                     liftIO $ done true
                  _ -> pure do
                     liftIO $ done false
                )
          r `shouldEqual` true

        it "should emit actions from the saga block" do
          r <- runIO' $ withCompletionVar \done -> do
            void $ mkStore (const id) {} do
              channel "foo"
                (\emit -> emit 1)
                (take case _ of
                  1 -> pure $ put "foo"
                  _ -> Nothing
                )
              take case _ of
                "foo" -> pure do
                  liftIO $ done true
                _ -> pure do
                  liftIO $ done false
          r `shouldEqual` true
