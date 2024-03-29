##### SECTION 1: Setup -----------------------------

# Create edx set and validation set

# Load required packages
library(tidyverse)
library(caret)
library(data.table)
library(recosystem)
library(gt)

# MovieLens 10M dataset:
# > https://grouplens.org/datasets/movielens/10m/
# > http://files.grouplens.org/datasets/movielens/ml-10m.zip

# Download the zipped file, unzip, and load both ratings and movies data
dl <- tempfile()
download.file("https://files.grouplens.org/datasets/movielens/ml-10m.zip", dl)

ratings <- fread(text = gsub("::", "\t", readLines(unzip(dl, "ml-10M100K/ratings.dat"))),
                 col.names = c("userId", "movieId", "rating", "timestamp"))

movies <- str_split_fixed(readLines(unzip(dl, "ml-10M100K/movies.dat")), "\\::", 3)
colnames(movies) <- c("movieId", "title", "genres")

# Clean up the classes for the movies data frame
movies <- as.data.frame(movies) %>% 
  mutate(movieId = as.numeric(movieId),
         title = as.character(title),
         genres = as.character(genres))

# Left join the ratings with movies using their movie ID 
movielens <- left_join(ratings, movies, by = "movieId")

# Validation set will be 10% of MovieLens data
set.seed(1, sample.kind="Rounding") # if using R 3.5 or earlier, use `set.seed(1)`
test_index <- createDataPartition(y = movielens$rating, times = 1, p = 0.1, list = FALSE)
edx <- movielens[-test_index,]
temp <- movielens[test_index,]

# Make sure userId and movieId in validation set are also in edx set
validation <- temp %>% 
  semi_join(edx, by = "movieId") %>%
  semi_join(edx, by = "userId")

# Add rows removed from validation set back into edx set
removed <- anti_join(temp, validation)
edx <- rbind(edx, removed)

# Remove extraneous data from environment 
rm(dl, ratings, movies, test_index, temp, movielens, removed)



##### SECTION 2: Introduction / Overview ---------------------------------------


# The MovieLens recommendation site was launched in 1997 by GroupLens Research (which is part of the University of Minnesota)
# Today, the MovieLens database is widely used for research and education purposes
# In total, there are approximately 11 million ratings and 8,500 movies 
# Each movie is rated by a user on a scale from 1/2 star up to 5 stars.


# The goal of this project is to train a machine learning algorithm using the inputs in one subset to predict movie ratings in the validation set
# The key steps that are performed include: 
#   Perform exploratory analysis on the data set in order to identify valuable variables
#   Generate a naive model to define a baseline RMSE and reference point for additional methods
#   Generate linear models using average movie ratings (movie effects) and average user ratings (user effects)
#   Utilize matrix factorization to achieve an RMSE below the desired threshold 
#   Present results and report conclusions



##### SECTION 3: Methods / Analysis --------------------------------------------


# This section explains the process and techniques used, including data cleaning, data exploration and visualization, insights gained, and modeling approach

###### SECTION 3.1: Exploratory Analysis ----------------------------------------

set.seed(92, sample.kind = "Rounding")
exp_edx <- edx[(sample(nrow(edx), size = 100000)), ]

exp_edx <- exp_edx %>%
  mutate(rating_date = lubridate::as_datetime(timestamp),
         rating_year = lubridate::year(rating_date), 
         rating_month = lubridate::month(rating_date),
         release_year = as.double(gsub("[\\(\\)]", "", regmatches(title, gregexpr("\\(.*?\\)", title))[[1]])),
         rating_gap = rating_year-release_year,
         movie_age = 2022-release_year)

movie_add <- exp_edx %>% 
  group_by(movieId) %>% 
  summarize(n_ratings = n(),
            avg_movie_rating = mean(rating))


# To find each user's average given rating
user_add <- exp_edx %>% 
  group_by(userId) %>% 
  summarize(avg_user_rating = mean(rating))


# Find average rating by individual genre and genre combinations
genre_list <- exp_edx %>%
  mutate(genre_rating = strsplit(genres, "|", fixed = TRUE)) %>%
  as_tibble() %>%
  select(rating, genre_rating) %>%
  unnest(genre_rating) %>%
  group_by(genre_rating) %>%
  summarize(avg_genre_rating = mean(rating), n = n())

genre_list %>%
  filter(n > 1000) %>%
  mutate(genre_rating = fct_reorder(genre_rating, avg_genre_rating)) %>%
  ggplot(aes(x = avg_genre_rating, y = genre_rating)) +
  geom_col(fill = "lightblue", alpha = 0.9) +
  labs(y = "Genre", 
       x = "Average Rating",
       title = "Average Rating by Genre",
       subtitle = "[Genres with > 1,000 Ratings]") +
  theme_classic() +
  scale_x_continuous(limits = c(0, 5), 
                     breaks = 0:5,
                     labels = 0:5) +
  theme(panel.grid.major.x = element_line(linetype = "dashed", color = "gray"))


genre_add <- cbind.data.frame(id = 1:length(unique(exp_edx$genres)),
                              genres = unique(exp_edx$genres)) %>%
  mutate(genre_rating = strsplit(genres, "|", fixed = TRUE)) %>%
  unnest(genre_rating) %>%
  inner_join(genre_list, by = "genre_rating") %>%
  group_by(id, genres) %>%
  summarize(avg_genre_rating = mean(avg_genre_rating)) 


# Combine all new fields
exp_edx <- left_join(exp_edx, movie_add, by = "movieId") 
exp_edx <- left_join(exp_edx, user_add, by = "userId")
exp_edx <- left_join(exp_edx, genre_add, by = "genres")


# View correlation plot for all numeric variables in the exploratory data set
corrplot::corrplot(exp_edx %>% select_if(., is.numeric) %>% cor(),
                   method = 'circle', order = 'alphabet')


# Remove all exploratory data from environment to free up space
rm(movie_add, user_add, genre_add, genre_list, exp_edx)  


###### SECTION 3.2: Actual Methods ----------------------------------------------

# Partition the data in to a test set with 20% and train set with 80%
# Set seed to 92 for reproducing results  
set.seed(92, sample.kind = "Rounding")
test_index <- createDataPartition(edx$rating, times = 1, p = 0.2, list = FALSE)
test_set <- edx %>% slice(test_index)
train_set <- edx %>% slice(-test_index)

# Optional: remove edx data set to free up space
rm(test_index, edx)

### Method #1: Naive Model
# Start off with a naive model that uses the average rating to predict movie ratings
mu_hat <- mean(train_set$rating)
naive_rmse <- RMSE(pred = mu_hat,
                   obs = test_set$rating)

### Method #2: Mean + Average Movie Rating
bi <- train_set %>%
  group_by(movieId) %>%
  summarize(b_i = mean(rating - mu_hat))

pred_bi <- mu_hat + test_set %>%
  left_join(bi, by = "movieId") %>%
  pull(b_i)

model1_rmse <- RMSE(pred = pred_bi, 
                    obs = test_set$rating, 
                    na.rm = TRUE)
rm(pred_bi)

### Method #3: Mean + Average Movie Rating + Average User Rating
bu <- train_set %>%
  left_join(bi, by = "movieId") %>%
  group_by(userId) %>%
  summarize(b_u = mean(rating - mu_hat - b_i))

pred_bu <- test_set %>%
  left_join(bi, by = "movieId") %>%
  left_join(bu, by = "userId") %>%
  mutate(pred_bu = mu_hat + b_i + b_u) %>%
  pull(pred_bu)

model2_rmse <- RMSE(pred = pred_bu, 
                    obs = test_set$rating, 
                    na.rm = TRUE)
rm(pred_bu)

### Method #4: Matrix factorization

# Followed general process described in recosystem vignette [https://cran.r-project.org/web/packages/recosystem/vignettes/introduction.html]
# Utilized their 5 main steps but was able to achieve desired RMSE with only required steps and default parameters 

# Convert the train and test sets into recosystem input format
set.seed(92, sample.kind = "Rounding")
train_data <-  with(train_set, data_memory(user_index = userId, 
                                           item_index = movieId,
                                           rating = rating,
                                           date = date))

test_data  <-  with(test_set,  data_memory(user_index = userId, 
                                           item_index = movieId, 
                                           rating = rating,
                                           date = date))

# Step 1. Create a reference class object using Reco()
r <-  Reco()

# Skipped Step 2. data tuning because it was taking a long time and we achieved desired results without it

# Step 3. Train the algorithm 
# Desired RMSE was achieved by 3rd iteration using the default options
# 10 latent factors, regularization parameters for user factors and item factors from 0 (L1) to 0.1 (L2), 20 iterations, and 20 bins
r$train(train_data)

# Skipped Step 4. export model via $output()

# Step 5. Calculate the predicted values (with $predict()) using Reco test_data, directly return R vector   
pred_MtrxFct <-  r$predict(test_data, out_memory()) 
head(pred_MtrxFct, n = 10)

# Find RMSE for matrix factorization predicted output 
MtrxFct_rmse <- RMSE(test_set$rating, pred_MtrxFct)


# Since the matrix factorization gets us where we need to be, repeat the above process but with our validation set
# Convert the validation set into recosystem input format
validation_data  <-  with(validation,  data_memory(user_index = userId, 
                                                   item_index = movieId, 
                                                   rating = rating,
                                                   date = date))

# Calculate the predicted values using Reco validation_data  
pred_MtrxFct_Val <- r$predict(validation_data, out_memory()) #out_memory(): Result should be returned as R objects

MtrxFct_rmse_val <- RMSE(validation$rating, pred_MtrxFct_Val)



##### SECTION 4: Results -------------------------------------------------------

# This section presents the modeling results and discusses the model performance
# Final results table with test on validation set
results_tbl <- tibble(
  Method = c("Method #1", "Method #2", "Method #3", "Method #4", "Final Validation"),
  Model = c("Naive Model", "Mean + Movie", "Mean + Movie + User", "Matrix Factorization", "Matrix Factorization"),
  RMSE = c(naive_rmse, model1_rmse, model2_rmse, MtrxFct_rmse, MtrxFct_rmse_val)) %>%
  mutate(`Estimated Points` = case_when(
    RMSE >= 0.90000 ~ 5, 
    RMSE >= 0.86550 & RMSE <= 0.89999 ~ 10,
    RMSE >= 0.86500 & RMSE <= 0.86549 ~ 15,
    RMSE >= 0.86490 & RMSE <= 0.86499 ~ 20,
    RMSE < 0.86490 ~ 25))

results_tbl %>%
  mutate(RMSE = round(RMSE, digits = 5)) %>%
  knitr::kable()


##### SECTION 5: Conclusion ----------------------------------------------------

# This section gives a brief summary of the report, its limitations and future work

# This Capstone project utilized the MovieLens data set to train and test multiple models and approaches for recommendor systems
# This project showcases the effects of movies and users on linear models
# It also showcases the strength of matrix factorization in reducing RMSE
# The desired RMSE threshold of < 0.86490 was surpassed, and a final validation RMSE of 0.83429 was achieved 
# For future work, the the matrix factorization model can be further refined with tuning parameters
# This would result in an optimized model and (likely) lower RMSE 
