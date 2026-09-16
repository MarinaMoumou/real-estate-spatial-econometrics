# Données

## Base agrégée incluse

`dep_data_tabular.csv` — 93 départements métropolitains, une ligne par
département, reconstruite à partir des sources brutes ci-dessous en suivant
exactement la même logique de nettoyage et d'agrégation que le script R
original (sections 1 à 8) : prix moyen au m², surface moyenne, nombre de
pièces moyen, part de maisons, nombre de transactions, population,
taux de chômage, nuitées touristiques.

Cette base ne couvre que la partie **tabulaire** de l'étude. La partie
géographique (fond de carte des départements, calcul de la superficie et de
la densité, matrice de voisinage, indices de Moran/LISA, modèles spatiaux
SAR/SEM/SDM) reste propre au script R original et nécessite le fond de
carte IGN listé ci-dessous — trop volumineux (>1 Go) pour être inclus ici.

`build_tabular_dataset.py` reproduit cette agrégation en Python à partir des
fichiers sources bruts, pour qui voudrait vérifier ou étendre le nettoyage
sans installer R.

## Sources brutes (à télécharger séparément)

| Source | Contenu | Lien |
|---|---|---|
| DVF 2022 | Transactions immobilières (ventes) | data.gouv.fr — "Demandes de valeurs foncières" / France real estate 2022 |
| INSEE | Estimations de population par département 1975-2023 | insee.fr |
| INSEE / DARES | Taux de chômage localisé par trimestre | insee.fr |
| INSEE | Fréquentation des hébergements touristiques par département | insee.fr |
| IGN | Fond de carte ADMIN-EXPRESS (contours départementaux) | geoservices.ign.fr |

Pour relancer l'analyse complète (y compris la partie spatiale), téléchargez
ces cinq fichiers dans un dossier `data_raw/` à la racine du projet — les
chemins du script R (`script/analyse_spatiale_immobilier.R`) pointent vers
ce dossier.
