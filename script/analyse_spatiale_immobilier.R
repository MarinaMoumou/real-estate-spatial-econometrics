# 0. PACKAGES
# ------------------------------------------------------------------------------
packages <- c(
  "data.table", "readxl", "sf", "spdep", "spatialreg",
  "ggplot2", "dplyr", "viridis", "classInt"
)

installed <- rownames(installed.packages())
for (p in packages) {
  if (!(p %in% installed)) install.packages(p)
}

library(data.table)
library(readxl)
library(sf)
library(spdep)
library(spatialreg)
library(ggplot2)
library(dplyr)
library(viridis)
library(classInt)

# 1. CHEMINS
# ------------------------------------------------------------------------------
# Sources brutes à télécharger séparément (voir data/README.md pour les liens) :
# placez-les dans un dossier local "data_raw/" à la racine du projet.
path_dvf <- "data_raw/france_total_real_estate_sales_2022.csv"
path_pop <- "data_raw/estim-pop-dep-sexe-gca-1975-2023.xls"
path_chom <- "data_raw/sl_etc_2025T3.xls"
path_tour <- "data_raw/DS_TOUR_FREQ.csv"
path_gpkg <- "data_raw/ADMIN-EXPRESS_4-0__GPKG_LAMB93_FXX_2026-02-16/ADMIN-EXPRESS/1_DONNEES_LIVRAISON_2026-02-00113/ADE_4-0_GPKG_LAMB93_FXX-ED2026-02-16/ADE_4-0_GPKG_LAMB93_FXX-ED2026-02-16.gpkg"

# 2. PARAMÈTRES GÉOGRAPHIQUES
# ------------------------------------------------------------------------------
dep_metropole <- c(sprintf("%02d", c(1:19, 21:95)), "2A", "2B")

# 3. IMPORT ET NETTOYAGE DVF
# ------------------------------------------------------------------------------
dvf <- fread(path_dvf)

dvf[, Valeur_fonciere := as.numeric(gsub(",", ".", `Valeur fonciere`))]

dvf <- dvf[`Nature mutation` == "Vente"]
dvf <- dvf[`Type local` %in% c("Appartement", "Maison")]

dvf <- dvf[!is.na(Valeur_fonciere) & Valeur_fonciere > 1000 & Valeur_fonciere < 10000000]
dvf <- dvf[!is.na(`Surface reelle bati`) & `Surface reelle bati` > 0]

dvf[, prix_m2 := Valeur_fonciere / `Surface reelle bati`]
dvf <- dvf[!is.na(prix_m2) & prix_m2 > 500 & prix_m2 < 20000]

dvf[, code_dep_clean := trimws(toupper(`Code departement`))]
dvf[grepl("^[0-9]$", code_dep_clean), code_dep_clean := paste0("0", code_dep_clean)]

dvf <- dvf[code_dep_clean %in% dep_metropole]

setdiff(dep_metropole, sort(unique(dvf$code_dep_clean)))

# 4. AGRÉGATION DÉPARTEMENTALE
# ------------------------------------------------------------------------------
dep_data <- dvf[, .(
  prix_moyen_m2   = mean(prix_m2, na.rm = TRUE),
  surface_moyenne = mean(`Surface reelle bati`, na.rm = TRUE),
  pieces_moyennes = mean(`Nombre pieces principales`, na.rm = TRUE),
  part_maisons    = mean(`Type local` == "Maison", na.rm = TRUE),
  nb_transactions = .N
), by = code_dep_clean]

setnames(dep_data, "code_dep_clean", "Code departement")

# 5. JOINTURE POPULATION 2022
# ------------------------------------------------------------------------------
population_2022 <- read_excel(
  path_pop,
  sheet = "2022",
  skip = 4,
  col_names = TRUE
)

population_2022 <- as.data.table(population_2022)

population_2022_clean <- population_2022[, .(
  Code_departement = trimws(as.character(.SD[[1]])),
  Departement      = trimws(as.character(.SD[[2]])),
  population       = as.numeric(.SD[[8]])
)]

population_2022_clean <- population_2022_clean[
  Code_departement %in% dep_metropole
]

dep_data_final <- merge(
  dep_data,
  population_2022_clean,
  by.x = "Code departement",
  by.y = "Code_departement",
  all.x = TRUE
)

# 6. JOINTURE CHÔMAGE 2022 (MOYENNE DES 4 TRIMESTRES)
# ------------------------------------------------------------------------------
chomage_2022 <- read_excel(
  path_chom,
  sheet = "Département",
  skip = 3,
  col_names = TRUE
)

chomage_2022 <- as.data.table(chomage_2022)

chomage_2022_clean <- chomage_2022[, .(
  Code_departement    = trimws(as.character(.SD[[1]])),
  Departement_chomage = trimws(as.character(.SD[[2]])),
  T1_2022 = as.numeric(.SD[[163]]),
  T2_2022 = as.numeric(.SD[[164]]),
  T3_2022 = as.numeric(.SD[[165]]),
  T4_2022 = as.numeric(.SD[[166]])
)]

chomage_2022_clean[, chomage_2022 :=
                     rowMeans(.SD, na.rm = TRUE),
                   .SDcols = c("T1_2022", "T2_2022", "T3_2022", "T4_2022")
]

chomage_2022_clean <- chomage_2022_clean[, .(
  Code_departement,
  chomage_2022
)]

chomage_2022_clean <- chomage_2022_clean[
  Code_departement %in% dep_metropole
]

dep_data_final <- merge(
  dep_data_final,
  chomage_2022_clean,
  by.x = "Code departement",
  by.y = "Code_departement",
  all.x = TRUE
)

# 7. JOINTURE TOURISME 2022
# ------------------------------------------------------------------------------
tourisme <- fread(
  path_tour,
  sep = ";",
  encoding = "UTF-8"
)

tourisme[, OBS_VALUE_num := as.numeric(gsub(",", ".", OBS_VALUE))]

nuitees_dep_2022 <- tourisme[
  TIME_PERIOD == 2022 &
    GEO_OBJECT == "DEP" &
    TOUR_MEASURE == "NUI" &
    TOUR_RESID == "_T",
  .(nuitees_2022 = sum(OBS_VALUE_num, na.rm = TRUE)),
  by = GEO
]

setnames(nuitees_dep_2022, "GEO", "Code departement")

nuitees_dep_2022[, nuitees_2022 := nuitees_2022 * 1000]

nuitees_dep_2022 <- nuitees_dep_2022[
  `Code departement` %in% dep_metropole
]

dep_data_final <- merge(
  dep_data_final,
  nuitees_dep_2022,
  by = "Code departement",
  all.x = TRUE
)

dep_data_final[, nuitees_par_habitant := nuitees_2022 / population]

# 8. VARIABLES DÉRIVÉES ATTRIBUTAIRES
# ------------------------------------------------------------------------------
dep_data_final[, transactions_par_habitant := nb_transactions / population]
dep_data_final[, log_population := log(population)]

# 9. CHARGEMENT DU FOND DE CARTE DÉPARTEMENTS
# ------------------------------------------------------------------------------
depts <- st_read(
  path_gpkg,
  layer = "departement",
  quiet = TRUE
)

depts$code_insee <- trimws(as.character(depts$code_insee))

depts <- depts[depts$code_insee %in% dep_data_final$`Code departement`, ]

depts_data <- depts %>%
  left_join(dep_data_final, by = c("code_insee" = "Code departement"))

# 10. CALCUL DE LA SURFACE ET DE LA DENSITÉ
# ------------------------------------------------------------------------------
depts_data$surface_km2 <- as.numeric(st_area(depts_data)) / 1e6
depts_data$densite_population <- depts_data$population / depts_data$surface_km2

# 11. VARIABLES DÉRIVÉES FINALES
# ------------------------------------------------------------------------------
depts_data$transactions_par_habitant <- depts_data$nb_transactions / depts_data$population
depts_data$log_population <- log(depts_data$population)
depts_data$log_prix_m2 <- log(depts_data$prix_moyen_m2)
depts_data$intensite_touristique <- depts_data$nuitees_par_habitant
depts_data$log_intensite_touristique <- log(depts_data$intensite_touristique)

# 12. ESDA : STATISTIQUES DESCRIPTIVES
# ------------------------------------------------------------------------------
summary(st_drop_geometry(depts_data)[, c(
  "prix_moyen_m2", "surface_moyenne", "pieces_moyennes",
  "part_maisons", "nb_transactions", "population",
  "transactions_par_habitant", "log_population",
  "chomage_2022", "densite_population",
  "nuitees_par_habitant"
)])

# 13. ESDA : HISTOGRAMMES ET BOXPLOTS
# ------------------------------------------------------------------------------
ggplot(st_drop_geometry(depts_data), aes(x = log(prix_moyen_m2))) +
  geom_histogram(bins = 20, fill = "steelblue", color = "white") +
  theme_minimal() +
  labs(
    title = "Histogramme du log du prix moyen au m²",
    x = "Log du prix moyen au m²",
    y = "Effectif"
  )

ggplot(st_drop_geometry(depts_data), aes(y = log(prix_moyen_m2))) +
  geom_boxplot(fill = "tomato", alpha = 0.7) +
  theme_minimal() +
  labs(
    title = "Boîte à moustaches du log du prix moyen au m²",
    y = "Log du prix moyen au m²"
  )

ggplot(st_drop_geometry(depts_data), aes(x = log(nuitees_par_habitant))) +
  geom_histogram(bins = 20, fill = "darkgreen", color = "white") +
  theme_minimal() +
  labs(
    title = "Histogramme du log de l'intensité touristique",
    x = "Log des nuitées par habitant",
    y = "Effectif"
  )

ggplot(st_drop_geometry(depts_data), aes(y = log(nuitees_par_habitant))) +
  geom_boxplot(fill = "darkgreen", alpha = 0.7) +
  theme_minimal() +
  labs(
    title = "Boîte à moustaches du log de l'intensité touristique",
    y = "Nuitées par habitant"
  )

ggplot(st_drop_geometry(depts_data), aes(x = log(densite_population))) +
  geom_histogram(bins = 20, fill = "purple", color = "white") +
  theme_minimal() +
  labs(
    title = "Histogramme du log de la densité",
    x = "Log densité",
    y = "Effectif"
  )

ggplot(st_drop_geometry(depts_data), aes(x = transactions_par_habitant)) +
  geom_histogram(bins = 20, fill = "orange", color = "white") +
  theme_minimal() +
  labs(
    title = "Histogramme des transactions par habitant",
    x = "Transactions / habitant",
    y = "Effectif"
  )

# 14. CARTES CHOROPLÈTHES
# ------------------------------------------------------------------------------
ggplot(depts_data) +
  geom_sf(aes(fill = log(prix_moyen_m2)), color = "white", linewidth = 0.2) +
  scale_fill_viridis_c(option = "magma", name = "Log prix au m²") +
  labs(title = "Log du prix moyen immobilier au m² par département") +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

ggplot(depts_data) +
  geom_sf(aes(fill = chomage_2022), color = "white", linewidth = 0.2) +
  scale_fill_viridis_c(option = "plasma", name = "Chômage 2022") +
  labs(title = "Taux de chômage moyen en 2022 par département") +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

ggplot(depts_data) +
  geom_sf(aes(fill = log(densite_population)), color = "white", linewidth = 0.2) +
  scale_fill_viridis_c(option = "viridis", name = "Log densité") +
  labs(title = "Log de la densité de population par département") +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

ggplot(depts_data) +
  geom_sf(aes(fill = log(nuitees_par_habitant)), color = "white", linewidth = 0.2) +
  scale_fill_viridis_c(option = "cividis", name = "Log nuitées / hab.") +
  labs(title = "Log de l’intensité touristique par département") +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

# 15. MATRICE DE CONTIGUÏTÉ QUEEN D’ORDRE 1
# ------------------------------------------------------------------------------
sf_use_s2(FALSE)

sum(st_is_empty(depts_data))
sum(!st_is_valid(depts_data))

neighbors_queen <- poly2nb(st_geometry(depts_data), queen = TRUE)

summary(neighbors_queen)

depts_data$nb_voisins <- sapply(neighbors_queen, length)

summary(depts_data$nb_voisins)
mean(depts_data$nb_voisins)
which(depts_data$nb_voisins == 0)
depts_data[depts_data$nb_voisins == 0, c("code_insee", "nom_officiel")]

ggplot(depts_data) +
  geom_sf(aes(fill = nb_voisins))

listw_queen <- nb2listw(neighbors_queen, style = "W", zero.policy = TRUE)

# 16. MORAN GLOBAL SUR LE LOG DU PRIX MOYEN AU M²
# ------------------------------------------------------------------------------
moran_global_prix <- moran.test(
  log(depts_data$prix_moyen_m2),
  listw_queen,
  zero.policy = TRUE
)
print(moran_global_prix)

moran_mc_prix <- moran.mc(
  log(depts_data$prix_moyen_m2),
  listw_queen,
  nsim = 999,
  zero.policy = TRUE
)
print(moran_mc_prix)

moran.plot(
  log(depts_data$prix_moyen_m2),
  listw_queen,
  zero.policy = TRUE,
  labels = FALSE,
  xlab = "Log du prix moyen au m²",
  ylab = "Spatial lag du log du prix moyen au m²"
)

# 17. MORAN LOCAL / LISA SUR LE LOG DU PRIX MOYEN AU M²
# ------------------------------------------------------------------------------
log_prix <- log(depts_data$prix_moyen_m2)

lisa_prix <- localmoran(
  log_prix,
  listw_queen,
  zero.policy = TRUE
)

depts_data$Ii      <- lisa_prix[, "Ii"]
depts_data$E.Ii    <- lisa_prix[, "E.Ii"]
depts_data$Var.Ii  <- lisa_prix[, "Var.Ii"]
depts_data$Z.Ii    <- lisa_prix[, "Z.Ii"]
depts_data$p_value <- lisa_prix[, "Pr(z != E(Ii))"]

lag_log_prix <- lag.listw(
  listw_queen,
  log_prix,
  zero.policy = TRUE
)

prix_centre <- log_prix - mean(log_prix, na.rm = TRUE)
lag_centre  <- lag_log_prix - mean(lag_log_prix, na.rm = TRUE)

depts_data$quadrant <- NA_character_
depts_data$quadrant[prix_centre > 0 & lag_centre > 0] <- "HH"
depts_data$quadrant[prix_centre < 0 & lag_centre < 0] <- "LL"
depts_data$quadrant[prix_centre > 0 & lag_centre < 0] <- "HL"
depts_data$quadrant[prix_centre < 0 & lag_centre > 0] <- "LH"

depts_data$lisa_sig <- ifelse(
  depts_data$p_value <= 0.10,
  depts_data$quadrant,
  "Non significatif"
)

depts_data$lisa_sig <- factor(
  depts_data$lisa_sig,
  levels = c("HH", "LL", "HL", "LH", "Non significatif")
)

table(depts_data$lisa_sig)

ggplot(depts_data) +
  geom_sf(aes(fill = lisa_sig), color = "white", linewidth = 0.2) +
  scale_fill_manual(
    values = c(
      "HH" = "red",
      "LL" = "blue",
      "HL" = "orange",
      "LH" = "lightblue",
      "Non significatif" = "grey85"
    ),
    drop = FALSE,
    name = "Clusters LISA"
  ) +
  theme_minimal() +
  labs(title = "Clusters locaux LISA du log du prix moyen au m²") +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

# 18. PRÉPARATION FINALE DES VARIABLES
# ------------------------------------------------------------------------------
model_data <- st_drop_geometry(depts_data)

colSums(is.na(model_data))

# 19. MODÈLE OLS DE RÉFÉRENCE
# ------------------------------------------------------------------------------
ols_formula <- log_prix_m2 ~ surface_moyenne + pieces_moyennes +
  part_maisons + chomage_2022 + densite_population +
  transactions_par_habitant + log_intensite_touristique

ols_mod <- lm(ols_formula, data = model_data)
summary(ols_mod)

# 20. MORAN SUR LES RÉSIDUS OLS
# ------------------------------------------------------------------------------
moran_res_ols <- lm.morantest(
  ols_mod,
  listw = listw_queen,
  zero.policy = TRUE
)
print(moran_res_ols)

# 21. CARTE DES RÉSIDUS OLS
# ------------------------------------------------------------------------------
depts_data$residus_ols <- residuals(ols_mod)

ggplot(depts_data) +
  geom_sf(aes(fill = residus_ols), color = "white", linewidth = 0.2) +
  scale_fill_gradient2(
    low = "blue",
    mid = "white",
    high = "red",
    midpoint = 0,
    name = "Résidus OLS"
  ) +
  labs(
    title = "Carte des résidus du modèle OLS",
    subtitle = "Résidus positifs en rouge, résidus négatifs en bleu"
  ) +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

# 22. TESTS LM
# ------------------------------------------------------------------------------
lm_tests <- lm.LMtests(
  ols_mod,
  listw = listw_queen,
  test = c("LMerr", "LMlag", "RLMerr", "RLMlag", "SARMA"),
  zero.policy = TRUE
)
print(lm_tests)

# 23. MODÈLE SAR
# ------------------------------------------------------------------------------
sar_mod <- lagsarlm(
  ols_formula,
  data = model_data,
  listw = listw_queen,
  zero.policy = TRUE
)
summary(sar_mod)

# 24. MODÈLE SEM
# ------------------------------------------------------------------------------
sem_mod <- errorsarlm(
  ols_formula,
  data = model_data,
  listw = listw_queen,
  zero.policy = TRUE
)
summary(sem_mod)

# 25. MODÈLE SDM
# ------------------------------------------------------------------------------
sdm_mod <- lagsarlm(
  ols_formula,
  data = model_data,
  listw = listw_queen,
  type = "mixed",
  zero.policy = TRUE
)
summary(sdm_mod)

# 26. COMPARAISON GLOBALE DES MODÈLES
# ------------------------------------------------------------------------------
AIC(ols_mod, sar_mod, sem_mod, sdm_mod)

logLik(ols_mod)
logLik(sar_mod)
logLik(sem_mod)
logLik(sdm_mod)

# 27. MORAN SUR LES RÉSIDUS DES MODÈLES
# ------------------------------------------------------------------------------
moran_sar <- moran.test(residuals(sar_mod), listw_queen, zero.policy = TRUE)
moran_sem <- moran.test(residuals(sem_mod), listw_queen, zero.policy = TRUE)
moran_sdm <- moran.test(residuals(sdm_mod), listw_queen, zero.policy = TRUE)

print(moran_sar)
print(moran_sem)
print(moran_sdm)

# 28. EXTRACTION DES RÉSULTATS DU MODÈLE FINAL (SEM)
# ------------------------------------------------------------------------------
sem_sum <- summary(sem_mod)

sem_results <- data.frame(
  Variable = rownames(sem_sum$Coef),
  Coefficient = sem_sum$Coef[, 1],
  Std_Error = sem_sum$Coef[, 2],
  z_value = sem_sum$Coef[, 3],
  p_value = sem_sum$Coef[, 4]
)

sem_results$Signif <- ifelse(
  sem_results$p_value < 0.01, "***",
  ifelse(sem_results$p_value < 0.05, "**",
         ifelse(sem_results$p_value < 0.10, "*", ""))
)

print(sem_results)

lambda_sem <- sem_mod$lambda
print(lambda_sem)

AIC(sem_mod)
logLik(sem_mod)

# 29. CARTE DES RÉSIDUS DU MODÈLE SEM
# ------------------------------------------------------------------------------
depts_data$residus_sem <- residuals(sem_mod)

ggplot(depts_data) +
  geom_sf(aes(fill = residus_sem), color = "white", linewidth = 0.2) +
  scale_fill_gradient2(
    low = "blue",
    mid = "white",
    high = "red",
    midpoint = 0,
    name = "Résidus SEM"
  ) +
  labs(
    title = "Carte des résidus du modèle SEM",
    subtitle = "Absence de structuration spatiale apparente"
  ) +
  theme_minimal() +
  theme(
    axis.text = element_blank(),
    axis.ticks = element_blank(),
    panel.grid.major = element_blank()
  )

# 30. IMPACTS SDM
# ------------------------------------------------------------------------------
imp_sdm <- impacts(sdm_mod, listw = listw_queen, R = 999)
summary(imp_sdm, zstats = TRUE, short = TRUE)