"""
Reconstruit la base départementale agrégée (hors composante géographique)
à partir des sources brutes, en suivant exactement la même logique que le
script R original (sections 1 à 8) : nettoyage DVF, agrégation par
département, puis jointure population / chômage / tourisme.

La partie géographique (fond de carte IGN, surface au km², densité,
matrice de voisinage, indices de Moran/LISA, modèles spatiaux) reste
propre au script R original : elle dépend du fichier IGN ADMIN-EXPRESS
(> 1 Go), non inclus dans ce dépôt.
"""

import pandas as pd
import numpy as np

DEP_METROPOLE = [f"{i:02d}" for i in list(range(1, 20)) + list(range(21, 96))] + ["2A", "2B"]

# ---------- 1. DVF : lecture par lots et nettoyage ----------
usecols = ["Nature mutation", "Valeur fonciere", "Type local",
           "Surface reelle bati", "Nombre pieces principales", "Code departement"]
dtype = {"Code departement": str}

chunks = []
reader = pd.read_csv(
    "data_raw/france_total_real_estate_sales_2022.csv",
    usecols=usecols, dtype=dtype, chunksize=500_000, low_memory=False,
)

for chunk in reader:
    chunk = chunk[chunk["Nature mutation"] == "Vente"]
    chunk = chunk[chunk["Type local"].isin(["Appartement", "Maison"])]

    chunk["valeur_fonciere"] = (
        chunk["Valeur fonciere"].astype(str).str.replace(",", ".", regex=False)
    )
    chunk["valeur_fonciere"] = pd.to_numeric(chunk["valeur_fonciere"], errors="coerce")

    chunk = chunk[chunk["valeur_fonciere"].notna()
                  & (chunk["valeur_fonciere"] > 1000)
                  & (chunk["valeur_fonciere"] < 10_000_000)]
    chunk = chunk[chunk["Surface reelle bati"].notna() & (chunk["Surface reelle bati"] > 0)]

    chunk["prix_m2"] = chunk["valeur_fonciere"] / chunk["Surface reelle bati"]
    chunk = chunk[(chunk["prix_m2"] > 500) & (chunk["prix_m2"] < 20_000)]

    chunk["code_dep_clean"] = chunk["Code departement"].str.strip().str.upper()
    chunk.loc[chunk["code_dep_clean"].str.match(r"^\d$"), "code_dep_clean"] = (
        "0" + chunk["code_dep_clean"]
    )
    chunk = chunk[chunk["code_dep_clean"].isin(DEP_METROPOLE)]

    chunks.append(chunk[["code_dep_clean", "prix_m2", "Surface reelle bati",
                          "Nombre pieces principales", "Type local"]])

dvf = pd.concat(chunks, ignore_index=True)
print(f"{len(dvf)} transactions retenues après nettoyage")

# ---------- 2. Agrégation départementale ----------
dep_data = dvf.groupby("code_dep_clean").agg(
    prix_moyen_m2=("prix_m2", "mean"),
    surface_moyenne=("Surface reelle bati", "mean"),
    pieces_moyennes=("Nombre pieces principales", "mean"),
    part_maisons=("Type local", lambda s: (s == "Maison").mean()),
    nb_transactions=("prix_m2", "size"),
).reset_index().rename(columns={"code_dep_clean": "code_departement"})

# ---------- 3. Population 2022 ----------
pop = pd.read_excel("data_raw/estim-pop-dep-sexe-gca-1975-2023.xls",
                     sheet_name="2022", skiprows=4, engine="xlrd")
pop_clean = pd.DataFrame({
    "code_departement": pop.iloc[:, 0].astype(str).str.strip(),
    "nom_departement": pop.iloc[:, 1].astype(str).str.strip(),
    "population": pd.to_numeric(pop.iloc[:, 7], errors="coerce"),
})
pop_clean = pop_clean[pop_clean["code_departement"].isin(DEP_METROPOLE)]

dep_data = dep_data.merge(pop_clean, on="code_departement", how="left")

# ---------- 4. Chômage 2022 (moyenne des 4 trimestres) ----------
chom = pd.read_excel("data_raw/sl_etc_2025T3.xls",
                      sheet_name="Département", skiprows=3, engine="xlrd")
chom_clean = pd.DataFrame({
    "code_departement": chom.iloc[:, 0].astype(str).str.strip(),
    "chomage_2022": chom.iloc[:, [162, 163, 164, 165]].apply(pd.to_numeric, errors="coerce").mean(axis=1),
})
chom_clean = chom_clean[chom_clean["code_departement"].isin(DEP_METROPOLE)]

dep_data = dep_data.merge(chom_clean, on="code_departement", how="left")

# ---------- 5. Tourisme 2022 ----------
tour = pd.read_csv("data_raw/DS_TOUR_FREQ.csv", sep=";", encoding="utf-8", dtype=str)
tour["obs_value"] = pd.to_numeric(tour["OBS_VALUE"].str.replace(",", ".", regex=False), errors="coerce")

nuitees = tour[(tour["TIME_PERIOD"] == "2022")
               & (tour["GEO_OBJECT"] == "DEP")
               & (tour["TOUR_MEASURE"] == "NUI")
               & (tour["TOUR_RESID"] == "_T")]
nuitees = nuitees.groupby("GEO")["obs_value"].sum().reset_index()
nuitees.columns = ["code_departement", "nuitees_2022"]
nuitees["nuitees_2022"] = nuitees["nuitees_2022"] * 1000
nuitees = nuitees[nuitees["code_departement"].isin(DEP_METROPOLE)]

dep_data = dep_data.merge(nuitees, on="code_departement", how="left")

# ---------- 6. Variables dérivées (hors géographie) ----------
dep_data["nuitees_par_habitant"] = dep_data["nuitees_2022"] / dep_data["population"]
dep_data["transactions_par_habitant"] = dep_data["nb_transactions"] / dep_data["population"]
dep_data["log_population"] = np.log(dep_data["population"])
dep_data["log_prix_m2"] = np.log(dep_data["prix_moyen_m2"])
dep_data["log_intensite_touristique"] = np.log(dep_data["nuitees_par_habitant"])

dep_data = dep_data.sort_values("code_departement").reset_index(drop=True)
print(dep_data.shape)
print(dep_data.head())

dep_data.to_csv("dep_data_tabular.csv", index=False)
print("Ecrit -> dep_data_tabular.csv")
