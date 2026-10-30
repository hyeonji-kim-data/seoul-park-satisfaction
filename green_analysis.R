
invisible(Sys.setlocale("LC_ALL", "C.UTF-8"))   # needed to read CSV files that contain Korean text
suppressPackageStartupMessages(library(dplyr))
library(tidyr)
library(ggplot2)

theme_set(theme_minimal(base_size = 12))
dir.create("figures", showWarnings = FALSE)
C_BLUE <- "#2a78d6"; C_ORANGE <- "#eb6834"; C_MUTED <- "#8a8984"


# ---------------------------------------------------------------------
# STEP 0. Load and merge the data
# The downloaded tables have multi-row headers, so this function reshapes them by year and item
# ---------------------------------------------------------------------
read_stat <- function(path, n_header, item_names, keep_filter = NULL) {
  raw   <- read.csv(path, header = FALSE, stringsAsFactors = FALSE,
                    fileEncoding = "UTF-8-BOM", check.names = FALSE)
  years <- as.character(raw[1, -(1:2)])
  body  <- raw[-(1:n_header), ]
  if (!is.null(keep_filter)) body <- body[body[[1]] == keep_filter, ]
  vals  <- body[, -(1:2)]
  colnames(vals) <- paste(years, rep(item_names, length.out = ncol(vals)), sep = "__")
  vals$region <- body[[2]]
  vals %>%
    pivot_longer(-region, names_to = c("year", ".value"), names_sep = "__") %>%
    mutate(year = as.integer(year),
           across(all_of(item_names), ~ suppressWarnings(as.numeric(ifelse(.x == "-", "0", .x)))))
}

# 1) Park ratio statistics: district area and park area
area <- read_stat("data/park_rate.csv", 3,
                  c("area", "park_total", "park_rate", "natl_park", "urban_nat", "built", "unbuilt")) %>%
  select(region, year, area, park_total)

# 2) Park area per person: city park area per person (m2) is the key measure
per <- read_stat("data/park_per.csv", 3,
                 c("park_k", "park_per", "city_k", "citypark_per", "walk_k", "walkpark_per")) %>%
  select(region, year, citypark_per, walkpark_per)

# 3) Green-space satisfaction: district rows only; satisfied = somewhat + very satisfied (%)
satis <- read_stat("data/satisfaction.csv", 2,
                   c("strongly_disagree", "disagree", "neutral", "agree", "strongly_agree", "score"),
                   keep_filter = "지역소분류") %>%
  mutate(satisfied = round(agree + strongly_agree, 1)) %>%   # round so equal values are not ranked differently due to floating-point error
  select(region, year, satisfied, score)

green <- area %>%
  filter(!region %in% c("소계", "서울대공원")) %>%      # drop the total row and non-district rows
  left_join(per,   by = c("region", "year")) %>%
  left_join(satis, by = c("region", "year")) %>%
  mutate(meets_standard = citypark_per >= 6)            # legal standard: 6 m2 of city park per person

stopifnot(all(table(green$year) == 25))   # check that all 25 districts are present every year

# English district names for output and figures
district_en <- c(
  "종로구" = "Jongno-gu",
  "중구" = "Jung-gu",
  "용산구" = "Yongsan-gu",
  "성동구" = "Seongdong-gu",
  "광진구" = "Gwangjin-gu",
  "동대문구" = "Dongdaemun-gu",
  "중랑구" = "Jungnang-gu",
  "성북구" = "Seongbuk-gu",
  "강북구" = "Gangbuk-gu",
  "도봉구" = "Dobong-gu",
  "노원구" = "Nowon-gu",
  "은평구" = "Eunpyeong-gu",
  "서대문구" = "Seodaemun-gu",
  "마포구" = "Mapo-gu",
  "양천구" = "Yangcheon-gu",
  "강서구" = "Gangseo-gu",
  "구로구" = "Guro-gu",
  "금천구" = "Geumcheon-gu",
  "영등포구" = "Yeongdeungpo-gu",
  "동작구" = "Dongjak-gu",
  "관악구" = "Gwanak-gu",
  "서초구" = "Seocho-gu",
  "강남구" = "Gangnam-gu",
  "송파구" = "Songpa-gu",
  "강동구" = "Gangdong-gu"
)
green$district <- unname(district_en[green$region])
stopifnot(!any(is.na(green$district)))
write.csv(green, "green_merged.csv", row.names = FALSE, fileEncoding = "UTF-8")
cat(sprintf("Data: %d districts x %d years\n", n_distinct(green$region), n_distinct(green$year)))


# ---------------------------------------------------------------------
# STEP 1. Districts that meet or fall below the legal standard (6 m2 per person)
# ---------------------------------------------------------------------
cat("\n[STEP 1] Districts below the legal standard (6 m2 of city park per person)\n")
print(green %>% group_by(year) %>%
        summarise(below_6m2 = sum(!meets_standard), meets_6m2 = sum(meets_standard)))
cat("Below the standard in 2021:\n")
print(green %>% filter(year == 2021, !meets_standard) %>%
        arrange(citypark_per) %>% select(district, citypark_per))

# Does satisfaction differ between districts that meet the standard and those that do not?
cat("\nMean satisfaction by standard (2021)\n")
print(green %>% filter(year == 2021) %>% group_by(meets_standard) %>%
        summarise(n = n(), satisfied_pct = round(mean(satisfied), 1)))


# ---------------------------------------------------------------------
# STEP 2. Rank correlation between city park area per person and satisfaction (Spearman)
# A few districts such as Jongno-gu and Jung-gu have extremely large park areas,
#   so comparing ranks is less affected by these outliers than comparing raw values
# rho ranges from -1 to 1; close to 0 means no relationship / p < 0.05 means unlikely to be chance
# ---------------------------------------------------------------------
spearman <- function(x, y) {
  t <- cor.test(x, y, method = "spearman", exact = FALSE)
  c(rho = unname(t$estimate), p = t$p.value)
}

yearly <- green %>%
  group_by(year) %>%
  summarise(rho = spearman(citypark_per, satisfied)["rho"],
            p   = spearman(citypark_per, satisfied)["p"],
            mean_satisfied = mean(satisfied))
cat("\n[STEP 2] Spearman correlation: city park per person vs. satisfaction\n")
print(as.data.frame(yearly), digits = 3)


# ---------------------------------------------------------------------
# STEP 3. Case: Is Jongno-gu, first in park area per person, also high in satisfaction?
# ---------------------------------------------------------------------
ranks <- green %>%
  group_by(year) %>%
  mutate(area_rank = rank(-citypark_per, ties.method = "min"),
         satisfaction_rank = rank(-satisfied, ties.method = "min")) %>%
  ungroup()

cat("\n[STEP 3] Jongno-gu: city park per person vs. satisfaction rank (out of 25)\n")
print(ranks %>% filter(district == "Jongno-gu") %>%
        select(year, citypark_per, area_rank, satisfied, satisfaction_rank) %>%
        left_join(yearly %>% select(year, seoul_mean = mean_satisfied), by = "year") %>%
        mutate(across(c(satisfied, seoul_mean), ~ round(.x, 1))))


# ---------------------------------------------------------------------
# STEP 4. Are satisfaction ranks stable from year to year?
# Compare each district's satisfaction rank across years (low correlation = ranks change a lot)
# ---------------------------------------------------------------------
wide_sat <- green %>% select(region, year, satisfied) %>%
  pivot_wider(names_from = year, values_from = satisfied, names_prefix = "y")
cat("\n[STEP 4] Year-to-year rank correlation of satisfaction\n")
print(round(cor(wide_sat[, -1], method = "spearman"), 2))


# ---------------------------------------------------------------------
# STEP 5. Change analysis: did satisfaction rise where park area grew? (2021 -> 2024)
# ---------------------------------------------------------------------
chg <- green %>% filter(year %in% c(2021, 2024)) %>%
  select(region, year, citypark_per, satisfied) %>%
  pivot_wider(names_from = year, values_from = c(citypark_per, satisfied)) %>%
  mutate(d_area = citypark_per_2024 - citypark_per_2021,
         d_sat  = satisfied_2024 - satisfied_2021)
dc <- spearman(chg$d_area, chg$d_sat)
cat("\n[STEP 5] Change from 2021 to 2024\n")
cat(sprintf("  City park per person: mean %+.2f m2 (range %+.2f to %+.2f)\n",
            mean(chg$d_area), min(chg$d_area), max(chg$d_area)))
cat(sprintf("  Satisfaction: mean %+.1f %%p (range %+.1f to %+.1f)\n",
            mean(chg$d_sat), min(chg$d_sat), max(chg$d_sat)))
cat(sprintf("  Rank correlation between the two changes: rho = %.3f (p = %.3f)\n", dc["rho"], dc["p"]))


# ---------------------------------------------------------------------
# STEP 6. Figures
# ---------------------------------------------------------------------
# Figure 1: city park area per person by district in 2021, with the legal standard line
g21 <- green %>% filter(year == 2021)
p1 <- ggplot(g21, aes(x = reorder(district, citypark_per), y = citypark_per, fill = meets_standard)) +
  geom_col(width = 0.7) +
  geom_hline(yintercept = 6, linetype = "dashed", colour = "grey30") +
  coord_flip() +
  scale_fill_manual(values = c(`TRUE` = C_BLUE, `FALSE` = C_ORANGE),
                    labels = c(`TRUE` = "Meets 6 m2", `FALSE` = "Below 6 m2")) +
  labs(title = "City park area per person by district (2021)",
       subtitle = "Dashed line: legal standard of 6 m2 per person",
       x = NULL, y = "City park area per person (m2)", fill = NULL) +
  theme(legend.position = "top")
ggsave("figures/01_citypark_per_2021.png", p1, width = 7, height = 7, dpi = 200)

# Figure 2: park area vs. satisfaction scatter plot by year (rho shown in each panel)
labels <- yearly %>% mutate(label = sprintf("rho = %.2f, p = %.2f", rho, p))
p2 <- ggplot(green, aes(x = citypark_per, y = satisfied)) +
  geom_point(colour = C_BLUE, size = 2, alpha = 0.8) +
  geom_text(data = labels, aes(x = Inf, y = Inf, label = label),
            hjust = 1.05, vjust = 1.5, size = 3.3, colour = "grey30") +
  scale_x_log10() +
  facet_wrap(~ year) +
  labs(title = "City park area per person vs. green-space satisfaction",
       subtitle = "25 Seoul districts per year, Spearman rank correlation",
       x = "City park area per person (m2, log scale)",
       y = "Satisfied residents (%)")
ggsave("figures/02_area_vs_satisfaction_by_year.png", p2, width = 9, height = 7, dpi = 200)

# Figure 3: park area rank vs. satisfaction rank by district in 2021 (dumbbell chart)
# Both values are converted to ranks (1-25) so they can be compared on one axis without a dual axis
# If the satisfaction dots do not follow the park area order, the two are unrelated
d21 <- ranks %>% filter(year == 2021) %>%
  arrange(area_rank) %>%
  mutate(district = factor(district, levels = rev(district)))
p3 <- ggplot(d21, aes(y = district)) +
  geom_segment(aes(x = area_rank, xend = satisfaction_rank, yend = district),
               colour = "#c4c3be", linewidth = 1) +
  geom_point(aes(x = area_rank, colour = "Park area per person"), size = 3) +
  geom_point(aes(x = satisfaction_rank, colour = "Green-space satisfaction"), size = 3) +
  scale_colour_manual(values = c("Park area per person" = C_BLUE, "Green-space satisfaction" = C_ORANGE),
                      breaks = c("Park area per person", "Green-space satisfaction")) +
  scale_x_continuous(breaks = c(1, 5, 10, 15, 20, 25)) +
  labs(title = "Park area rank vs. satisfaction rank by district (2021)",
       subtitle = "Sorted by park area. A long gray line means the two ranks disagree.",
       x = "Rank among 25 districts (1 = highest)", y = NULL, colour = NULL) +
  theme(legend.position = "top", panel.grid.minor = element_blank())
ggsave("figures/03_area_vs_satisfaction_rank_2021.png", p3, width = 7, height = 8, dpi = 200)

cat("\nFigures saved to figures/\n")
