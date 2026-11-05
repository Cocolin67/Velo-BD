-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--
--  Contenu : création de la base, des 20 tables, des clés, des contraintes
--  d'intégrité (CHECK, UNIQUE) et des index.
--  Non inclus (étapes suivantes) : triggers (historisation, coût des locations,
--  règles « un seul emprunt par usager »), vues, données factices.
--
--  Conventions :
--    - noms de tables et de colonnes sans accents, en snake_case ;
--    - clés étrangères en ON DELETE RESTRICT par défaut (on conserve l'historique) ;
--      CASCADE uniquement pour les tables « filles » sans existence propre ;
--    - les colonnes utilisées dans un CHECK n'ont pas d'action CASCADE / SET NULL
--      (restriction de MySQL) ;
--    - InnoDB partout (clés étrangères, transactions).
-- =============================================================================

CREATE DATABASE IF NOT EXISTS velo_libre_service
    CHARACTER SET utf8mb4
    COLLATE utf8mb4_unicode_ci;

USE velo_libre_service;

-- -----------------------------------------------------------------------------
--  1. UTILISATEURS ET RÔLES (héritage par tables liées)
-- -----------------------------------------------------------------------------

CREATE TABLE utilisateur (
    id_utilisateur    INT UNSIGNED NOT NULL AUTO_INCREMENT,
    nom               VARCHAR(100) NOT NULL,
    prenom            VARCHAR(100) NOT NULL,
    email             VARCHAR(255) NOT NULL,
    mot_de_passe_hash VARCHAR(255) NOT NULL,          -- hash (bcrypt / argon2), jamais le mot de passe en clair
    date_inscription  DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (id_utilisateur),
    -- Index unique : connexion par email (recherche à chaque authentification)
    UNIQUE KEY uq_utilisateur_email (email),
    -- Recherche / tri par nom dans les écrans d'administration
    KEY idx_utilisateur_nom (nom, prenom)
) ENGINE=InnoDB;

CREATE TABLE usager (
    id_utilisateur INT UNSIGNED NOT NULL,
    date_naissance DATE         NULL,
    telephone      VARCHAR(20)  NULL,
    PRIMARY KEY (id_utilisateur),
    CONSTRAINT fk_usager_utilisateur
        FOREIGN KEY (id_utilisateur) REFERENCES utilisateur (id_utilisateur)
        ON DELETE CASCADE
) ENGINE=InnoDB;

CREATE TABLE operateur (
    id_utilisateur INT UNSIGNED NOT NULL,
    matricule      VARCHAR(20)  NOT NULL,
    specialite     ENUM('regulation', 'maintenance') NOT NULL,
    PRIMARY KEY (id_utilisateur),
    UNIQUE KEY uq_operateur_matricule (matricule),
    CONSTRAINT fk_operateur_utilisateur
        FOREIGN KEY (id_utilisateur) REFERENCES utilisateur (id_utilisateur)
        ON DELETE CASCADE
) ENGINE=InnoDB;

-- Un administrateur est un opérateur (cohérent avec le diagramme de cas d'utilisation)
CREATE TABLE administrateur (
    id_utilisateur INT UNSIGNED NOT NULL,
    PRIMARY KEY (id_utilisateur),
    CONSTRAINT fk_administrateur_operateur
        FOREIGN KEY (id_utilisateur) REFERENCES operateur (id_utilisateur)
        ON DELETE CASCADE
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  2. STATIONS ET BORNES
-- -----------------------------------------------------------------------------

CREATE TABLE station (
    id_station   INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    nom          VARCHAR(150)  NOT NULL,
    adresse      VARCHAR(255)  NOT NULL,
    latitude     DECIMAL(9, 6) NOT NULL,
    longitude    DECIMAL(9, 6) NOT NULL,
    etat_station ENUM('en_service', 'hors_service', 'en_travaux') NOT NULL DEFAULT 'en_service',
    PRIMARY KEY (id_station),
    UNIQUE KEY uq_station_nom (nom),
    -- Filtre des stations par état (carte en temps réel : seulement « en_service »)
    KEY idx_station_etat (etat_station),
    -- Recherche géographique par rectangle (latitude puis longitude)
    KEY idx_station_geo (latitude, longitude),
    CONSTRAINT ck_station_latitude  CHECK (latitude  BETWEEN -90  AND 90),
    CONSTRAINT ck_station_longitude CHECK (longitude BETWEEN -180 AND 180)
) ENGINE=InnoDB;

-- Le nombre de bornes d'une station est dérivé (COUNT sur cette table), non stocké.
CREATE TABLE borne (
    id_borne    INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    id_station  INT UNSIGNED      NOT NULL,
    num_borne   SMALLINT UNSIGNED NOT NULL,
    etat_borne  ENUM('fonctionnelle', 'hors_service') NOT NULL DEFAULT 'fonctionnelle',
    PRIMARY KEY (id_borne),
    -- Identifiant relatif du MCD : une borne est numérotée au sein de sa station.
    -- Cet index couvre aussi la clé étrangère id_station (préfixe gauche).
    UNIQUE KEY uq_borne_station_num (id_station, num_borne),
    CONSTRAINT fk_borne_station
        FOREIGN KEY (id_station) REFERENCES station (id_station)
) ENGINE=InnoDB;

-- Instantanés périodiques de remplissage, pour les statistiques par tranche horaire
CREATE TABLE releve_station (
    id_station           INT UNSIGNED      NOT NULL,
    horodatage           DATETIME          NOT NULL,
    nb_velos_mecaniques  SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    nb_velos_electriques SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    nb_bornes_libres     SMALLINT UNSIGNED NOT NULL DEFAULT 0,
    PRIMARY KEY (id_station, horodatage),
    -- Taux de remplissage par tranche horaire, toutes stations confondues.
    -- Index couvrant pour sp_stat_remplissage_stations (lecture de l'index seul).
    KEY idx_releve_horodatage (horodatage, id_station,
                               nb_velos_mecaniques, nb_velos_electriques, nb_bornes_libres),
    CONSTRAINT fk_releve_station
        FOREIGN KEY (id_station) REFERENCES station (id_station)
        ON DELETE CASCADE
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  3. FLOTTE
-- -----------------------------------------------------------------------------

CREATE TABLE velo (
    id_velo              INT UNSIGNED NOT NULL AUTO_INCREMENT,
    type_velo            ENUM('mecanique', 'electrique') NOT NULL,
    date_mise_en_service DATE         NOT NULL,
    etat_velo            ENUM('disponible', 'en_location', 'en_atelier', 'defectueux')
                                      NOT NULL DEFAULT 'disponible',
    niveau_batterie      TINYINT UNSIGNED NULL,       -- 0..100 ; NULL pour un vélo mécanique
    id_borne             INT UNSIGNED NULL,           -- position actuelle ; NULL si en location ou en atelier
    PRIMARY KEY (id_velo),
    -- Une borne n'accueille qu'un seul vélo : unicité (plusieurs NULL autorisés)
    UNIQUE KEY uq_velo_borne (id_borne),
    -- Vélos disponibles par type (affichage temps réel, rééquilibrage)
    KEY idx_velo_etat_type (etat_velo, type_velo),
    CONSTRAINT fk_velo_borne
        FOREIGN KEY (id_borne) REFERENCES borne (id_borne),
    CONSTRAINT ck_velo_batterie_plage
        CHECK (niveau_batterie IS NULL OR niveau_batterie BETWEEN 0 AND 100),
    CONSTRAINT ck_velo_batterie_electrique
        CHECK (type_velo = 'electrique' OR niveau_batterie IS NULL),
    -- Un vélo ne peut être qu'à un seul endroit à la fois
    CONSTRAINT ck_velo_position
        CHECK (etat_velo NOT IN ('en_location', 'en_atelier') OR id_borne IS NULL)
) ENGINE=InnoDB;

-- Historique des changements d'état (alimenté par trigger)
CREATE TABLE historique_etat (
    id_hist_etat BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_velo      INT UNSIGNED    NOT NULL,
    date_heure   DATETIME        NOT NULL DEFAULT CURRENT_TIMESTAMP,
    etat_velo    ENUM('disponible', 'en_location', 'en_atelier', 'defectueux') NOT NULL,
    PRIMARY KEY (id_hist_etat),
    -- Historique d'un vélo, du plus récent au plus ancien ; couvre la clé étrangère id_velo
    KEY idx_hist_etat_velo_date (id_velo, date_heure),
    -- Taux d'indisponibilité de la flotte sur une période
    KEY idx_hist_etat_etat_date (etat_velo, date_heure),
    CONSTRAINT fk_hist_etat_velo
        FOREIGN KEY (id_velo) REFERENCES velo (id_velo)
) ENGINE=InnoDB;

-- Historique des positions : une ligne par période passée sur une borne, en location ou en atelier
CREATE TABLE historique_position (
    id_hist_pos      BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_velo          INT UNSIGNED    NOT NULL,
    id_borne         INT UNSIGNED    NULL,            -- renseignée si type_position = 'borne'
    date_heure_debut DATETIME        NOT NULL,
    date_heure_fin   DATETIME        NULL,            -- NULL = position actuelle
    type_position    ENUM('borne', 'en_location', 'en_atelier') NOT NULL,
    PRIMARY KEY (id_hist_pos),
    KEY idx_hist_pos_velo_debut  (id_velo,  date_heure_debut),
    -- Taux de remplissage d'une borne / station dans le temps
    KEY idx_hist_pos_borne_debut (id_borne, date_heure_debut),
    CONSTRAINT fk_hist_pos_velo
        FOREIGN KEY (id_velo)  REFERENCES velo (id_velo),
    CONSTRAINT fk_hist_pos_borne
        FOREIGN KEY (id_borne) REFERENCES borne (id_borne),
    CONSTRAINT ck_hist_pos_dates
        CHECK (date_heure_fin IS NULL OR date_heure_fin >= date_heure_debut),
    CONSTRAINT ck_hist_pos_borne
        CHECK (type_position <> 'borne' OR id_borne IS NOT NULL)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  4. FORMULES, TARIFICATION ET ABONNEMENTS
-- -----------------------------------------------------------------------------

CREATE TABLE formule (
    id_formule            INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    libelle               VARCHAR(100)      NOT NULL,   -- ticket journée, mensuel, annuel, tarif réduit
    prix                  DECIMAL(8, 2)     NOT NULL,
    duree_validite_jours  SMALLINT UNSIGNED NOT NULL,
    duree_gratuite_min    SMALLINT UNSIGNED NOT NULL DEFAULT 0,   -- gratuité par trajet
    supplement_electrique DECIMAL(6, 2)     NOT NULL DEFAULT 0.00,
    PRIMARY KEY (id_formule),
    UNIQUE KEY uq_formule_libelle (libelle),
    CONSTRAINT ck_formule_prix       CHECK (prix >= 0),
    CONSTRAINT ck_formule_validite   CHECK (duree_validite_jours > 0),
    CONSTRAINT ck_formule_supplement CHECK (supplement_electrique >= 0)
) ENGINE=InnoDB;

-- Tranches facturées au-delà de la durée gratuite : rang 1 = première tranche, etc.
CREATE TABLE tranche_tarifaire (
    id_formule        INT UNSIGNED      NOT NULL,
    rang              TINYINT UNSIGNED  NOT NULL,
    duree_tranche_min SMALLINT UNSIGNED NOT NULL,
    tarif_tranche     DECIMAL(6, 2)     NOT NULL,
    PRIMARY KEY (id_formule, rang),
    CONSTRAINT fk_tranche_formule
        FOREIGN KEY (id_formule) REFERENCES formule (id_formule)
        ON DELETE CASCADE,
    CONSTRAINT ck_tranche_duree CHECK (duree_tranche_min > 0),
    CONSTRAINT ck_tranche_tarif CHECK (tarif_tranche >= 0)
) ENGINE=InnoDB;

CREATE TABLE abonnement (
    id_abonnement      INT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_utilisateur     INT UNSIGNED NOT NULL,           -- l'usager titulaire
    id_formule         INT UNSIGNED NOT NULL,
    date_debut         DATETIME     NOT NULL,
    date_fin           DATETIME     NOT NULL,
    statut             ENUM('actif', 'expire', 'resilie') NOT NULL DEFAULT 'actif',
    renouvellement_auto BOOLEAN     NOT NULL DEFAULT FALSE,
    PRIMARY KEY (id_abonnement),
    -- Recherche de l'abonnement valide d'un usager à l'emprunt (accès le plus fréquent)
    KEY idx_abo_usager_statut_fin (id_utilisateur, statut, date_fin),
    -- Traitement périodique des expirations et des renouvellements
    KEY idx_abo_statut_fin (statut, date_fin),
    -- Recettes et répartition par formule
    KEY idx_abo_formule (id_formule),
    CONSTRAINT fk_abo_usager
        FOREIGN KEY (id_utilisateur) REFERENCES usager (id_utilisateur),
    CONSTRAINT fk_abo_formule
        FOREIGN KEY (id_formule) REFERENCES formule (id_formule),
    CONSTRAINT ck_abo_dates CHECK (date_fin > date_debut)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  5. FACTURATION ET LOCATIONS
-- -----------------------------------------------------------------------------

CREATE TABLE facture (
    id_facture      INT UNSIGNED  NOT NULL AUTO_INCREMENT,
    id_abonnement   INT UNSIGNED  NOT NULL,
    date_emission   DATETIME      NOT NULL DEFAULT CURRENT_TIMESTAMP,
    montant_total   DECIMAL(10, 2) NOT NULL,
    statut_paiement ENUM('en_attente', 'payee', 'echouee', 'remboursee') NOT NULL DEFAULT 'en_attente',
    PRIMARY KEY (id_facture),
    -- Factures d'un abonnement, par date ; couvre la clé étrangère id_abonnement
    KEY idx_facture_abo_date (id_abonnement, date_emission),
    -- Recettes par période
    KEY idx_facture_date (date_emission),
    -- Suivi des impayés
    KEY idx_facture_statut (statut_paiement),
    CONSTRAINT fk_facture_abo
        FOREIGN KEY (id_abonnement) REFERENCES abonnement (id_abonnement),
    CONSTRAINT ck_facture_montant CHECK (montant_total >= 0)
) ENGINE=InnoDB;

CREATE TABLE location (
    id_location             BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_abonnement           INT UNSIGNED    NOT NULL,     -- l'usager s'en déduit
    id_velo                 INT UNSIGNED    NOT NULL,
    id_borne_depart         INT UNSIGNED    NOT NULL,     -- la station de départ s'en déduit
    id_borne_arrivee        INT UNSIGNED    NULL,         -- NULL tant que le vélo n'est pas rendu
    date_heure_emprunt      DATETIME        NOT NULL,
    date_heure_restitution  DATETIME        NULL,         -- NULL = location en cours
    -- Durée calculée automatiquement par la base (arrondie à la minute inférieure)
    duree_min               INT UNSIGNED
        GENERATED ALWAYS AS (TIMESTAMPDIFF(MINUTE, date_heure_emprunt, date_heure_restitution)) STORED,
    cout                    DECIMAL(8, 2)   NULL,         -- calculé par trigger à la restitution
    id_facture              INT UNSIGNED    NULL,
    -- Colonnes auxiliaires : valent NULL quand la location est terminée.
    -- Leur index UNIQUE garantit « au plus une location en cours » par vélo et par abonnement.
    velo_en_cours           INT UNSIGNED
        GENERATED ALWAYS AS (IF(date_heure_restitution IS NULL, id_velo, NULL)) STORED,
    abo_en_cours            INT UNSIGNED
        GENERATED ALWAYS AS (IF(date_heure_restitution IS NULL, id_abonnement, NULL)) STORED,
    PRIMARY KEY (id_location),
    UNIQUE KEY uq_location_velo_en_cours (velo_en_cours),
    UNIQUE KEY uq_location_abo_en_cours  (abo_en_cours),
    -- Historique d'un vélo ; couvre la clé étrangère id_velo
    KEY idx_loc_velo_emprunt   (id_velo, date_heure_emprunt),
    -- Locations d'un abonnement / d'un usager ; couvre la clé étrangère id_abonnement
    KEY idx_loc_abo_emprunt    (id_abonnement, date_heure_emprunt),
    -- Trajets par période, heures de pointe, origine-destination, indicateurs du jour.
    -- Index COUVRANT : toutes les colonnes lues par sp_stat_trajets_par_periode,
    -- sp_stat_heures_pointe et sp_stat_trajets_od y figurent, la table n'est donc
    -- pas relue (pas d'accès à la clé primaire pour chaque trajet de la période).
    KEY idx_loc_emprunt        (date_heure_emprunt, date_heure_restitution,
                                id_borne_depart, id_borne_arrivee, duree_min, cout),
    -- Trajets origine-destination les plus fréquents ; couvre id_borne_depart
    KEY idx_loc_depart_arrivee (id_borne_depart, id_borne_arrivee),
    -- Arrivées par borne / station ; couvre id_borne_arrivee
    KEY idx_loc_arrivee_resti  (id_borne_arrivee, date_heure_restitution),
    -- Locations d'une facture ; couvre la clé étrangère id_facture
    KEY idx_loc_facture        (id_facture),
    CONSTRAINT fk_loc_abo
        FOREIGN KEY (id_abonnement)    REFERENCES abonnement (id_abonnement),
    CONSTRAINT fk_loc_velo
        FOREIGN KEY (id_velo)          REFERENCES velo (id_velo),
    CONSTRAINT fk_loc_borne_depart
        FOREIGN KEY (id_borne_depart)  REFERENCES borne (id_borne),
    CONSTRAINT fk_loc_borne_arrivee
        FOREIGN KEY (id_borne_arrivee) REFERENCES borne (id_borne),
    CONSTRAINT fk_loc_facture
        FOREIGN KEY (id_facture)       REFERENCES facture (id_facture),
    CONSTRAINT ck_loc_dates
        CHECK (date_heure_restitution IS NULL OR date_heure_restitution >= date_heure_emprunt),
    -- Restitution et borne d'arrivée sont renseignées ensemble, ou pas du tout
    CONSTRAINT ck_loc_restitution
        CHECK ((date_heure_restitution IS NULL) = (id_borne_arrivee IS NULL)),
    CONSTRAINT ck_loc_cout CHECK (cout IS NULL OR cout >= 0)
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  6. MAINTENANCE ET SIGNALEMENTS
-- -----------------------------------------------------------------------------

CREATE TABLE intervention (
    id_intervention         INT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_velo                 INT UNSIGNED NOT NULL,
    id_operateur            INT UNSIGNED NOT NULL,
    date_retrait            DATETIME     NOT NULL,        -- retrait du vélo du réseau
    date_debut_reparation   DATETIME     NULL,
    date_remise_circulation DATETIME     NULL,
    description_travaux     TEXT         NOT NULL,
    PRIMARY KEY (id_intervention),
    -- Historique de maintenance d'un vélo ; couvre la clé étrangère id_velo
    KEY idx_interv_velo_retrait (id_velo, date_retrait),
    -- Interventions d'un opérateur ; couvre la clé étrangère id_operateur
    KEY idx_interv_operateur    (id_operateur, date_retrait),
    -- Interventions en cours (non remises en circulation)
    KEY idx_interv_remise       (date_remise_circulation),
    CONSTRAINT fk_interv_velo
        FOREIGN KEY (id_velo)      REFERENCES velo (id_velo),
    CONSTRAINT fk_interv_operateur
        FOREIGN KEY (id_operateur) REFERENCES operateur (id_utilisateur),
    CONSTRAINT ck_interv_debut
        CHECK (date_debut_reparation IS NULL OR date_debut_reparation >= date_retrait),
    CONSTRAINT ck_interv_remise
        CHECK (date_remise_circulation IS NULL
               OR date_remise_circulation >= COALESCE(date_debut_reparation, date_retrait))
) ENGINE=InnoDB;

CREATE TABLE signalement (
    id_signalement  INT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_utilisateur  INT UNSIGNED NOT NULL,                -- auteur du signalement
    id_velo         INT UNSIGNED NULL,                    -- cible : un vélo...
    id_station      INT UNSIGNED NULL,                    -- ... ou une station
    id_intervention INT UNSIGNED NULL,                    -- intervention déclenchée, le cas échéant
    date_heure      DATETIME     NOT NULL DEFAULT CURRENT_TIMESTAMP,
    description     TEXT         NOT NULL,
    statut          ENUM('ouvert', 'pris_en_charge', 'clos') NOT NULL DEFAULT 'ouvert',
    PRIMARY KEY (id_signalement),
    -- File de traitement : signalements ouverts, les plus anciens d'abord
    KEY idx_sig_statut_date (statut, date_heure),
    -- Signalements d'un vélo (vérifier s'il est défectueux) ; couvre id_velo
    KEY idx_sig_velo        (id_velo, date_heure),
    -- Signalements d'une station ; couvre id_station
    KEY idx_sig_station     (id_station, date_heure),
    -- Signalements d'un auteur ; couvre id_utilisateur
    KEY idx_sig_utilisateur (id_utilisateur),
    -- Signalements rattachés à une intervention ; couvre id_intervention
    KEY idx_sig_intervention (id_intervention),
    CONSTRAINT fk_sig_utilisateur
        FOREIGN KEY (id_utilisateur)  REFERENCES utilisateur (id_utilisateur),
    CONSTRAINT fk_sig_velo
        FOREIGN KEY (id_velo)         REFERENCES velo (id_velo),
    CONSTRAINT fk_sig_station
        FOREIGN KEY (id_station)      REFERENCES station (id_station),
    CONSTRAINT fk_sig_intervention
        FOREIGN KEY (id_intervention) REFERENCES intervention (id_intervention),
    -- Un signalement vise soit un vélo, soit une station : exactement l'un des deux
    CONSTRAINT ck_sig_cible CHECK ((id_velo IS NULL) <> (id_station IS NULL))
) ENGINE=InnoDB;

-- -----------------------------------------------------------------------------
--  7. RÉGULATION DU RÉSEAU
-- -----------------------------------------------------------------------------

CREATE TABLE vehicule (
    id_vehicule     INT UNSIGNED      NOT NULL AUTO_INCREMENT,
    immatriculation VARCHAR(15)       NOT NULL,
    capacite_velos  SMALLINT UNSIGNED NOT NULL,
    PRIMARY KEY (id_vehicule),
    UNIQUE KEY uq_vehicule_immat (immatriculation),
    CONSTRAINT ck_vehicule_capacite CHECK (capacite_velos > 0)
) ENGINE=InnoDB;

CREATE TABLE tournee (
    id_tournee       INT UNSIGNED NOT NULL AUTO_INCREMENT,
    id_operateur     INT UNSIGNED NOT NULL,
    id_vehicule      INT UNSIGNED NOT NULL,
    date_heure_debut DATETIME     NOT NULL,
    date_heure_fin   DATETIME     NULL,
    PRIMARY KEY (id_tournee),
    -- Tournées d'un opérateur / d'un véhicule, par date ; couvrent les clés étrangères
    KEY idx_tournee_operateur (id_operateur, date_heure_debut),
    KEY idx_tournee_vehicule  (id_vehicule,  date_heure_debut),
    CONSTRAINT fk_tournee_operateur
        FOREIGN KEY (id_operateur) REFERENCES operateur (id_utilisateur),
    CONSTRAINT fk_tournee_vehicule
        FOREIGN KEY (id_vehicule)  REFERENCES vehicule (id_vehicule),
    CONSTRAINT ck_tournee_dates
        CHECK (date_heure_fin IS NULL OR date_heure_fin >= date_heure_debut)
) ENGINE=InnoDB;

-- Un vélo déplacé d'une station à une autre pendant une tournée
CREATE TABLE ligne_tournee (
    id_tournee             INT UNSIGNED      NOT NULL,
    num_ligne              SMALLINT UNSIGNED NOT NULL,
    id_velo                INT UNSIGNED      NOT NULL,
    id_station_depart      INT UNSIGNED      NOT NULL,
    id_station_arrivee     INT UNSIGNED      NOT NULL,
    date_heure_deplacement DATETIME          NOT NULL,
    PRIMARY KEY (id_tournee, num_ligne),
    -- Déplacements d'un vélo ; couvre la clé étrangère id_velo
    KEY idx_ligne_velo    (id_velo, date_heure_deplacement),
    -- Flux entre stations (stations qui se vident / se remplissent) ; couvrent les deux clés étrangères
    KEY idx_ligne_depart  (id_station_depart,  date_heure_deplacement),
    KEY idx_ligne_arrivee (id_station_arrivee, date_heure_deplacement),
    CONSTRAINT fk_ligne_tournee
        FOREIGN KEY (id_tournee)         REFERENCES tournee (id_tournee)
        ON DELETE CASCADE,
    CONSTRAINT fk_ligne_velo
        FOREIGN KEY (id_velo)            REFERENCES velo (id_velo),
    CONSTRAINT fk_ligne_station_depart
        FOREIGN KEY (id_station_depart)  REFERENCES station (id_station),
    CONSTRAINT fk_ligne_station_arrivee
        FOREIGN KEY (id_station_arrivee) REFERENCES station (id_station),
    CONSTRAINT ck_ligne_stations CHECK (id_station_depart <> id_station_arrivee)
) ENGINE=InnoDB;
