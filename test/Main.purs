module Test.Main where

import Prelude

import Control.Monad.Fork.Class (fork)
import Control.Monad.Fork.Class as Fork
import Control.Monad.Rec.Class (forever)
import Control.Safely (replicateM_)
import Data.Array as A
import Data.Maybe (Maybe(..))
import Data.Newtype (wrap)
import Data.Time.Duration (Milliseconds(..))
import Debug.Trace (traceM)
import Effect (Effect)
import Effect.Aff (Aff, delay, launchAff_)
import Effect.Aff.AVar as AVar
import Effect.Aff.Class (liftAff)
import Effect.Class (liftEffect)
import Effect.Ref as Ref
import React.Redux as Redux
import Redux.Saga (Saga', sagaMiddleware)
import Redux.Saga as Saga
import Test.Spec (describe, it)
import Test.Spec.Assertions (shouldEqual)
import Test.Spec.Reporter as Spec
import Test.Spec.Runner as Spec

-- data Action = SearchChanged String
-- type GlobalState = {}

mkStore
  :: ∀ state action eff
   . Redux.Reducer action state
  -> state
  -> Saga' Unit state action action Unit
  -> Effect (Redux.ReduxStore state action)
mkStore reducer initialState saga =
  Redux.createStore
    reducer
    initialState $
      Redux.applyMiddleware [ sagaMiddleware saga ]

withCompletionVar :: ∀ a. ((a -> Aff Unit) -> Aff Unit) -> Aff a
withCompletionVar f = do
  completedVar <- AVar.empty
  liftEffect $ launchAff_ $ f (AVar.put <@> completedVar)
  AVar.take completedVar

main :: Effect Unit
main = Spec.run' (Spec.defaultConfig { timeout = Just 2000 }) [ Spec.consoleReporter ] do
  describe "sagas" do
    describe "take" do
      it "should be able to miss events" do
        r <- withCompletionVar \done -> do
          void $ liftEffect $
            mkStore (wrap $ const identity) {} do
              f <- fork do
                x <- Saga.take (Just <<< pure <<< identity)
                void $ fork do
                  liftAff $ delay $ 20.0 # Milliseconds
                  liftAff $ done x
                liftAff $ delay $ 10.0 # Milliseconds
                y <- Saga.take (Just <<< pure <<< identity)
                liftAff $ done y
              Saga.put 1
              Saga.put 2
              Fork.join f
        r `shouldEqual` 1

      it "should run matching action handler" do
        r <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            void $ fork do
              x <- Saga.take \i -> do
                Just (pure i)
              liftAff $ done x
            Saga.put 1
        r `shouldEqual` 1

      it "should ignore non-matching actions" do
        r <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            void $ fork do
              Saga.take \i -> case i of
                n | n == 2 ->
                  Just do
                    liftAff $ done n
                _ ->
                  Nothing
            Saga.put 1
            Saga.put 2
        r `shouldEqual` 2

      it "should be able to run repeatedly" do
        r <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            ref <- liftEffect $ Ref.new []
            void $ fork do
              replicateM_ 3 do
                Saga.take \i ->
                  Just do
                    liftEffect $ Ref.modify (_ `A.snoc` i) ref
              liftEffect (Ref.read ref) >>= liftAff <<< done
            Saga.put 1
            Saga.put 2
            Saga.put 3
            Saga.put 4
        r `shouldEqual` [1, 2, 3]

      it "should block the thread" do
        r <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            ref <- liftEffect $ Ref.new []
            void $ fork do
              liftAff $ delay $ 10.0 # Milliseconds
              liftAff $ done true
            void $ Saga.take (const Nothing)
            liftAff $ done false
        r `shouldEqual` true

--     describe "error handling" do
--       -- TODO: How to actually catch these? or at least test that it's
--       -- actually crashing
--       pending' "should terminate on errors" do
--         void $ runIO' $ withCompletionVar \_ -> do
--           void $ mkStore (wrap $ const identity) {} do
--             liftAff $ void $ throwError $ error "oh no"

--       -- TODO: How to actually catch these? or at least test that it's
--       -- actually crashing
--       pending' "sub-sagas should bubble up errors" do
--         void $ runIO' $ withCompletionVar \_ -> do
--           void $ mkStore (wrap $ const identity) {} do
--             void $ fork do
--               liftAff $ void $ throwError $ error "oh no"

--       -- TODO: How to actually catch these? or at least test that it's
--       -- actually crashing
--       pending' "sub-sagas should bubble up errors" do
--         void $ runIO' $ withCompletionVar \_ -> do
--           void $ mkStore (wrap $ const identity) {} do
--             void $ fork do
--               liftAff $ void $ throwError $ error "oh no"
--             void $ Saga.take case _ of _ -> Nothing

    describe "Saga.put" do
      it "should not overflow the stack" do
        let target = 2000
        v <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            ref <- liftEffect $ Ref.new 1
            void $ fork $ forever $ Saga.take do
              const $ Just do
                liftEffect $ void $ Ref.modify (_ + 1) ref
            replicateM_ target $ Saga.put unit
            liftEffect (Ref.read ref) >>= liftAff <<< done
        v `shouldEqual` target

    describe "forks" do
      describe "local envs" do
        it "should work" do
          r <- withCompletionVar \done -> do
            void $ liftEffect $ mkStore (wrap $ const identity) {} do
              void $ fork $ Saga.localEnv (const 10) do
                Saga.askEnv >>= liftAff <<< done
          r `shouldEqual` 10

      it "should be joinable (2)" do
        n <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            ref <- liftEffect $ Ref.new 0
            t <- fork do
              Saga.take $ const $ Just do
                liftEffect $ void $ Ref.modify (_ + 1) ref
            Saga.put unit
            Fork.join t
            liftEffect (Ref.read ref) >>= liftAff <<< done
        n `shouldEqual` 1

      it "should be joinable (3)" do
        n <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            ref <- liftEffect $ Ref.new 0
            t <- fork do
              replicateM_ 10 do
                Saga.take $ const $ Just do
                  liftEffect $ void $ Ref.modify (_ + 1) ref
            replicateM_ 10 $ Saga.put unit
            Fork.join t
            liftEffect (Ref.read ref) >>= liftAff <<< done
        n `shouldEqual` 10

      it "should wait for child processes (3)" do
        x <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            void $ fork do
              void $ fork do
                 void $ forever $ Saga.take case _ of
                  5 -> pure $ liftAff $ done true
                  _ -> Nothing
            Saga.put 1
            Saga.put 2
            Saga.put 3
            Saga.put 4
            Saga.put 5
        x `shouldEqual` true

      it "should wait for nested child processes" do
        x <- withCompletionVar \done -> do
          void $ liftEffect $ mkStore (wrap $ const identity) {} do
            task <- fork do
              void $ fork do
                liftAff $ delay $ 100.0 # Milliseconds
                liftAff $ done true
            void $ Fork.join task
            liftAff $ done false
        x `shouldEqual` true

--       describe "cancellation" do
--         it "should be able to cancel forks" do
--           x <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               task <- forkNamed "level 1" do
--                 task' <- forkNamed "level 2" do
--                   liftAff $ void $ forever do
--                     delay $ 0.0 # Milliseconds
--                   liftIO $ done false
--                 cancelTask task'
--               joinTask task
--               liftIO $ done true
--           x `shouldEqual` true

--         it "should be able to cancel forks with channels" do
--           x <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               task <- fork do
--                 task' <- fork do
--                   void $ channel "..." (\_ -> pure unit) do
--                     void $ forever $ Saga.take $ const Nothing
--                     liftIO $ done false
--                 cancelTask task'
--               joinTask task
--               liftIO $ done true
--           x `shouldEqual` true

--         it "should be able to cancel forks (2)" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               ref <- liftEff $ newRef []
--               task <- fork do
--                 forever do
--                   Saga.take \i -> pure do
--                     liftEff $ modifyRef ref (_ `A.snoc` i)
--               for_ [ 1, 2, 3 ] Saga.put

--               liftAff $ delay $ 10.0 # Milliseconds
--               cancelTask task

--               for_ [ 4, 5, 6, 7, 8, 9 ] Saga.put
--               liftAff $ delay $ 10.0 # Milliseconds

--               liftEff (readRef ref) >>= liftIO <<< done
--           r `shouldEqual` [1, 2, 3]
--           liftAff $ delay $ 10.0 # Milliseconds

--         it "should be able to cancel forks (3)" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               ref <- liftEff $ newRef []

--               aT <- forkNamed "a" $ do
--                 liftEff $ modifyRef ref $ flip A.snoc "a:start"
--                 liftAff $ delay $ 20.0 # Milliseconds
--                 liftEff $ modifyRef ref $ flip A.snoc "a:done"
--                 pure "a"

--               bT <- forkNamed "b" $ "b" <$ do
--                 _ <- forkNamed "b" $ "b" <$ do
--                   forever $ do
--                     liftEff $ modifyRef ref $ flip A.snoc "b"
--                     liftAff $ delay $ 10.0 # Milliseconds
--                 forever $ do
--                   liftEff $ modifyRef ref $ flip A.snoc "b"
--                   liftAff $ delay $ 10.0 # Milliseconds

--               cT <- forkNamed "c" $ "c" <$ do
--                 forever $ do
--                   liftEff $ modifyRef ref $ flip A.snoc "c"
--                   liftAff $ delay $ 10.0 # Milliseconds

--               x <- joinTask aT <|> joinTask bT <|> joinTask cT
--               liftAff $ x `shouldEqual` "a"

--               -- this tests that 'b' and 'c' are no longer writing to the ref
--               liftAff $ delay $ 20.0 # Milliseconds

--               liftEff (readRef ref) >>= liftIO <<< done
--           r `shouldEqual` ["a:start", "b", "b", "c", "b", "b", "c", "a:done"]

--         it "should be able to cancel forks (4)" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               ref <- liftEff $ newRef unit
--               let saga = do
--                     aT <- forkNamed "a" $ do
--                       localEnv identity do
--                         t <- forkNamed "a level 2" do
--                           liftAff $ delay $ 20.0 # Milliseconds
--                           pure "a"
--                         joinTask t

--                     bT <-
--                       forkNamed "foo" $ "b(0)" <$ do
--                         forkNamed "b(1)" $ do
--                           forkNamed "b(2)" $ do
--                             Saga.take case _ of _ -> Nothing

--                     cT <-
--                       forkNamed "foo" $ "c(0)" <$ do
--                         forkNamed "c(1)" $ do
--                           forkNamed "c(2)" $ do
--                             Saga.take case _ of _ -> Nothing

--                     (joinTask aT <|> joinTask bT) <|> joinTask cT

--               uT <- forkNamed "uT" saga
--               yT <- forkNamed "yT" saga
--               void $ joinTask uT <|> joinTask yT

--               liftEff (readRef ref) >>= liftIO <<< done
--           r `shouldEqual` unit
--           liftAff $ delay $ 10.0 # Milliseconds

--         it "debounce" do
--           x <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               ref <- liftEff $ newRef 0

--               void $ fork $
--                 debounce (100.0 # Milliseconds) $
--                   const $ Just do
--                     liftEff $ modifyRef ref (_ + 1)

--               Saga.put unit
--               liftAff $ delay $ 10.0 # Milliseconds

--               Saga.put unit
--               liftAff $ delay $ 10.0 # Milliseconds

--               Saga.put unit
--               liftAff $ delay $ 10.0 # Milliseconds

--               liftAff $ delay $ 200.0 # Milliseconds
--               liftEff (readRef ref) >>= liftIO <<< done
--           x `shouldEqual` 1

--       describe "channels" do
--         it "should call emitter block" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               void $ channel "foo"
--                 (\emit -> done true)
--                 (pure unit)
--           r `shouldEqual` true

--         it "should emit to the saga block" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               void $ channel "foo"
--                 (\emit -> emit "foo")
--                 (Saga.take case _ of
--                   Right "foo" -> pure do
--                      liftIO $ done true
--                   _ -> pure do
--                      liftIO $ done false
--                 )
--           r `shouldEqual` true

--         it "should emit actions from the saga block" do
--           r <- runIO' $ withCompletionVar \done -> do
--             void $ mkStore (wrap $ const identity) {} do
--               void $ channel "foo"
--                 (\emit -> emit 1)
--                 do
--                   Saga.take case _ of
--                     Right 1 -> Just $ Saga.put "foo"
--                     _ -> Nothing
--                   Saga.take case _ of
--                     Left "qux" -> Just $ liftIO $ done true
--                     _ -> Nothing
--               Saga.take case _ of
--                 "foo" -> Just $ Saga.put "qux"
--                 _ -> Just $ liftIO $ done false
--           r `shouldEqual` true
