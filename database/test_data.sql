-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  DONNÉES DE TEST : jeu de données aléatoire, de taille modeste, pour essayer le site
--
--  À exécuter après schema.sql, triggers.sql, procedures.sql et demo_accounts.sql :
--      mysql -h 127.0.0.1 -P 3306 -u root -p --default-character-set=utf8mb4 < database/test_data.sql
--  ou depuis phpMyAdmin : base velo_libre_service > Importer > ce fichier.
--  Compatible MySQL 8 et MariaDB 10.4+ (WAMP, XAMPP). Pas de DELIMITER, pas de procédure.
--
--  Différences avec seed.sql :
--    - s'ajoute aux données existantes (pas besoin d'une base vide) : chaque exécution
--      ajoute un nouveau lot, numéroté (stations « Gare de Belfort 2 », etc.) ;
--    - passe par les triggers (coûts, historiques, règles d'emprunt), comme l'application ;
--    - les usagers et opérateurs créés peuvent se connecter, mot de passe Demo1234! :
--        test.usager.<lot>.<n>@velo.local      (n = 1 à 40)
--        test.operateur.<lot>.<n>@velo.local   (1 et 2 : maintenance, 3 : régulation)
--    - le compte usager@velo.local reçoit un abonnement annuel (s'il n'en a pas)
--      et un historique de trajets ; il reste libre d'emprunter un vélo.
--
--  Contenu d'un lot (les volumes se règlent ci-dessous) :
--    15 stations (dont une en travaux et une hors service), 8 à 14 bornes chacune,
--    environ 100 vélos, 40 usagers abonnés, 3 opérateurs, ~2 000 trajets sur 90 jours,
--    5 locations en cours, des signalements (ouverts, pris en charge, clos),
--    des interventions, 2 véhicules et 6 tournées, 30 jours de relevés horaires.
--
--  À NE PAS utiliser en production. Pour repartir de zéro : CALL sp_seed_vider('OUI');
--  (seed.sql) ou réimporter schema.sql.
-- =============================================================================

USE velo_libre_service;

-- Même collation que les tables : sinon, comparer une colonne à un texte calculé
-- échoue sous MySQL 8 (« Illegal mix of collations », défaut utf8mb4_0900_ai_ci)
SET NAMES utf8mb4 COLLATE utf8mb4_unicode_ci;

-- Réglages
SET @nb_usagers     = 40;      -- usagers créés (40 au plus : listes de prénoms/noms)
SET @nb_locations   = 2000;    -- trajets terminés tirés au hasard (un peu moins après filtrage)
SET @jours          = 90;      -- profondeur de l'historique des trajets, en jours
SET @jours_releves  = 30;      -- relevés horaires de remplissage des stations, en jours

-- Hash bcrypt de « Demo1234! » (le même que demo_accounts.sql)
SET @hash = '$2y$12$FB6YDEohtnAKI0RBchd1l.rB6J2YpvqbpplL78I9WKVc/wWEt2XFK';

-- Les triggers doivent rester actifs (voir triggers.sql)
SET @seed_mode = 0;

-- Numéro du lot : 1 au premier passage, puis 2, 3...
SET @lot = (SELECT COALESCE(MAX(CAST(SUBSTRING_INDEX(SUBSTRING_INDEX(email, '.', 3), '.', -1) AS UNSIGNED)), 0) + 1
              FROM utilisateur WHERE email LIKE 'test.usager.%@velo.local');
-- En texte : un nombre dans CONCAT() donne une chaîne binaire, qui ne retrouve pas les emails
SET @lot = CAST(@lot AS CHAR);
SET @sfx = IF(@lot = '1', '', CONCAT(' ', @lot));

-- -----------------------------------------------------------------------------
--  Tables de travail (supprimées à la fin). Ce sont des tables ordinaires et non
--  TEMPORARY : MySQL interdit d'utiliser deux fois une table temporaire dans une requête.
-- -----------------------------------------------------------------------------
DROP TABLE IF EXISTS tmp_test_n, tmp_test_lieu, tmp_test_station, tmp_test_velo, tmp_test_borne,
                     tmp_test_usager, tmp_test_abo, tmp_test_tirage, tmp_test_choix,
                     tmp_test_actif, tmp_test_tournee, tmp_test_releve;

CREATE TABLE tmp_test_n (n INT UNSIGNED NOT NULL PRIMARY KEY) ENGINE=InnoDB;
CREATE TABLE tmp_test_lieu (k INT UNSIGNED NOT NULL PRIMARY KEY, nom VARCHAR(150) NOT NULL, adresse VARCHAR(255) NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_station (k INT UNSIGNED NOT NULL PRIMARY KEY, id_station INT UNSIGNED NOT NULL,
    etat VARCHAR(15) NOT NULL, nb_bornes INT NOT NULL, nb_fonct INT NOT NULL DEFAULT 0, remplissage DOUBLE NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_velo (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_velo INT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_borne (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_borne INT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_usager (rn INT UNSIGNED NOT NULL PRIMARY KEY, prenom VARCHAR(100) NOT NULL, nom VARCHAR(100) NOT NULL,
    r_formule DOUBLE NOT NULL, r_ancien DOUBLE NOT NULL, renouv TINYINT NOT NULL,
    id_utilisateur INT UNSIGNED NULL, id_formule INT UNSIGNED NULL, date_debut DATETIME NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_abo (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_abonnement INT UNSIGNED NOT NULL, jours INT NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_tirage (n INT UNSIGNED NOT NULL PRIMARY KEY, r_abo INT NOT NULL, r_velo INT NOT NULL,
    r_dep INT NOT NULL, r_arr INT NOT NULL, r_jour DOUBLE NOT NULL, r_we DOUBLE NOT NULL,
    heure INT NOT NULL, minute INT NOT NULL, duree INT NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_choix (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_velo INT UNSIGNED NOT NULL, id_borne INT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_actif (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_abonnement INT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_tournee (rn INT UNSIGNED NOT NULL PRIMARY KEY, id_tournee INT UNSIGNED NOT NULL) ENGINE=InnoDB;
CREATE TABLE tmp_test_releve (id_station INT UNSIGNED NOT NULL, horodatage DATETIME NOT NULL,
    nb_fonct INT NOT NULL, velos INT NOT NULL, PRIMARY KEY (id_station, horodatage)) ENGINE=InnoDB;

-- Nombres de 1 à 10 000
INSERT INTO tmp_test_n (n)
SELECT a.d + 10 * b.d + 100 * c.d + 1000 * e.d + 1
  FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) a
 CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) b
 CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) c
 CROSS JOIN (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
        UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) e;

START TRANSACTION;

-- -----------------------------------------------------------------------------
--  1. Formules et tarifs (mêmes valeurs que seed.sql ; rien n'est modifié s'ils existent)
-- -----------------------------------------------------------------------------
INSERT IGNORE INTO formule (libelle, prix, duree_validite_jours, duree_gratuite_min, supplement_electrique)
VALUES ('Ticket journée',     5.00,   1, 30, 1.00),
       ('Abonnement mensuel', 15.00, 30, 45, 0.50),
       ('Abonnement annuel', 120.00, 365, 45, 0.50),
       ('Tarif réduit',      60.00, 365, 45, 0.25);

INSERT IGNORE INTO tranche_tarifaire (id_formule, rang, duree_tranche_min, tarif_tranche)
SELECT f.id_formule, t.rang, t.duree, t.tarif
  FROM formule f
  JOIN (SELECT 'Ticket journée' AS libelle, 1 AS rang, 30 AS duree, 1.00 AS tarif
        UNION ALL SELECT 'Ticket journée',     2, 30, 2.00
        UNION ALL SELECT 'Abonnement mensuel', 1, 30, 1.00
        UNION ALL SELECT 'Abonnement annuel',  1, 30, 1.00
        UNION ALL SELECT 'Tarif réduit',       1, 30, 0.50) t
    ON t.libelle = f.libelle;

SET @f_mensuel = (SELECT id_formule FROM formule WHERE libelle = 'Abonnement mensuel');
SET @f_annuel  = (SELECT id_formule FROM formule WHERE libelle = 'Abonnement annuel');
SET @f_reduit  = (SELECT id_formule FROM formule WHERE libelle = 'Tarif réduit');

-- -----------------------------------------------------------------------------
--  2. Stations (Belfort) et bornes
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_lieu (k, nom, adresse) VALUES
    ( 1, 'Gare de Belfort',          'Avenue Wilson, 90000 Belfort'),
    ( 2, 'Place d''Armes',           'Place d''Armes, 90000 Belfort'),
    ( 3, 'Place de la République',   'Place de la République, 90000 Belfort'),
    ( 4, 'Lion de Belfort',          'Rue du Général Lecourbe, 90000 Belfort'),
    ( 5, 'Techn''hom UTBM',          'Rue Thierry Mieg, 90010 Belfort'),
    ( 6, 'Parc de la Douce',         'Avenue du Général Leclerc, 90000 Belfort'),
    ( 7, 'Faubourg de France',       'Faubourg de France, 90000 Belfort'),
    ( 8, 'Quai Vauban',              'Quai Vauban, 90000 Belfort'),
    ( 9, 'Maison du Peuple',         'Place de la Résistance, 90000 Belfort'),
    (10, 'Les 4 As',                 'Rue de l''As de Carreau, 90000 Belfort'),
    (11, 'Atria',                    'Avenue de l''Espérance, 90000 Belfort'),
    (12, 'Jean Jaurès',              'Avenue Jean Jaurès, 90000 Belfort'),
    (13, 'Résidences Bellevue',      'Rue de Bellevue, 90000 Belfort'),
    (14, 'Glacis du Château',        'Rue des Glacis, 90000 Belfort'),
    (15, 'Pépinière',                'Rue de la Pépinière, 90000 Belfort');

INSERT INTO station (nom, adresse, latitude, longitude, etat_station)
SELECT CONCAT(l.nom, @sfx), l.adresse,
       ROUND(47.6380 + (RAND() - 0.5) * 0.035, 6),
       ROUND(6.8630  + (RAND() - 0.5) * 0.050, 6),
       CASE l.k WHEN 14 THEN 'en_travaux' WHEN 15 THEN 'hors_service' ELSE 'en_service' END
  FROM tmp_test_lieu l;

-- Remplissage cible : de 15 % à 90 % selon la station, 0 si elle n'est pas en service
INSERT INTO tmp_test_station (k, id_station, etat, nb_bornes, remplissage)
SELECT l.k, s.id_station, s.etat_station, 8 + FLOOR(RAND() * 7),
       IF(s.etat_station = 'en_service', 0.15 + RAND() * 0.75, 0)
  FROM tmp_test_lieu l
  JOIN station s ON s.nom = CONCAT(l.nom, @sfx);

INSERT INTO borne (id_station, num_borne, etat_borne)
SELECT s.id_station, n.n, IF(RAND() < 0.05, 'hors_service', 'fonctionnelle')
  FROM tmp_test_station s
  JOIN tmp_test_n n ON n.n <= s.nb_bornes;

UPDATE tmp_test_station s
   SET s.nb_fonct = (SELECT COUNT(*) FROM borne b
                      WHERE b.id_station = s.id_station AND b.etat_borne = 'fonctionnelle');

-- -----------------------------------------------------------------------------
--  3. Vélos : posés sur une partie des bornes fonctionnelles des stations en service
--     (trg_velo_ai initialise HISTORIQUE_ETAT et HISTORIQUE_POSITION)
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_choix (rn, id_velo, id_borne)        -- sert ici de tirage : id_velo = 1 si électrique
SELECT b.id_borne, IF(RAND() < 0.35, 1, 0), b.id_borne
  FROM borne b
  JOIN tmp_test_station s ON s.id_station = b.id_station
 WHERE b.etat_borne = 'fonctionnelle' AND s.etat = 'en_service' AND RAND() < s.remplissage;

INSERT INTO velo (type_velo, date_mise_en_service, etat_velo, niveau_batterie, id_borne)
SELECT IF(c.id_velo = 1, 'electrique', 'mecanique'),
       CURDATE() - INTERVAL (150 + FLOOR(RAND() * 900)) DAY,
       'disponible',
       IF(c.id_velo = 1, 15 + FLOOR(RAND() * 86), NULL),
       c.id_borne
  FROM tmp_test_choix c;

DELETE FROM tmp_test_choix;

INSERT INTO tmp_test_velo (rn, id_velo)
SELECT ROW_NUMBER() OVER (ORDER BY v.id_velo), v.id_velo
  FROM velo v
  JOIN borne b ON b.id_borne = v.id_borne
  JOIN tmp_test_station s ON s.id_station = b.id_station;
SET @nb_velos = (SELECT COUNT(*) FROM tmp_test_velo);

INSERT INTO tmp_test_borne (rn, id_borne)
SELECT ROW_NUMBER() OVER (ORDER BY b.id_borne), b.id_borne
  FROM borne b
  JOIN tmp_test_station s ON s.id_station = b.id_station
 WHERE b.etat_borne = 'fonctionnelle' AND s.etat = 'en_service';
SET @nb_bornes = (SELECT COUNT(*) FROM tmp_test_borne);

-- -----------------------------------------------------------------------------
--  4. Usagers et opérateurs (mot de passe : Demo1234!)
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_usager (rn, prenom, nom, r_formule, r_ancien, renouv)
SELECT n.n,
       ELT(1 + FLOOR(RAND() * 20), 'Camille', 'Lucas', 'Léa', 'Hugo', 'Manon', 'Nathan', 'Chloé', 'Louis',
           'Inès', 'Jules', 'Emma', 'Gabriel', 'Sarah', 'Arthur', 'Zoé', 'Théo', 'Jade', 'Tom', 'Lina', 'Noah'),
       ELT(1 + FLOOR(RAND() * 20), 'Martin', 'Bernard', 'Thomas', 'Petit', 'Robert', 'Richard', 'Durand',
           'Dubois', 'Moreau', 'Laurent', 'Simon', 'Michel', 'Lefebvre', 'Leroy', 'Roux', 'David', 'Bertrand',
           'Morel', 'Fournier', 'Girard'),
       RAND(), RAND(), IF(RAND() < 0.4, 1, 0)
  FROM tmp_test_n n
 WHERE n.n <= LEAST(@nb_usagers, 40);

INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash, date_inscription)
SELECT t.nom, t.prenom, CONCAT('test.usager.', @lot, '.', t.rn, '@velo.local'), @hash,
       NOW() - INTERVAL (400 + FLOOR(RAND() * 300)) DAY
  FROM tmp_test_usager t;

UPDATE tmp_test_usager t
  JOIN utilisateur u ON u.email = CONCAT('test.usager.', @lot, '.', t.rn, '@velo.local')
   SET t.id_utilisateur = u.id_utilisateur;
SET @nb_usagers = (SELECT COUNT(*) FROM tmp_test_usager);

INSERT INTO usager (id_utilisateur, date_naissance, telephone)
SELECT t.id_utilisateur,
       CURDATE() - INTERVAL (18 * 365 + FLOOR(RAND() * 50 * 365)) DAY,
       CONCAT('06', LPAD(FLOOR(RAND() * 100000000), 8, '0'))
  FROM tmp_test_usager t;

INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash, date_inscription)
VALUES ('Garnier', 'Julien', CONCAT('test.operateur.', @lot, '.1@velo.local'), @hash, NOW() - INTERVAL 500 DAY),
       ('Faure',   'Claire', CONCAT('test.operateur.', @lot, '.2@velo.local'), @hash, NOW() - INTERVAL 420 DAY),
       ('Mercier', 'Karim',  CONCAT('test.operateur.', @lot, '.3@velo.local'), @hash, NOW() - INTERVAL 380 DAY);

INSERT INTO operateur (id_utilisateur, matricule, specialite)
SELECT u.id_utilisateur,
       CONCAT('T', @lot, '-', SUBSTRING_INDEX(SUBSTRING_INDEX(u.email, '@', 1), '.', -1)),
       IF(u.email LIKE CONCAT('test.operateur.', @lot, '.3@%'), 'regulation', 'maintenance')
  FROM utilisateur u
 WHERE u.email LIKE CONCAT('test.operateur.', @lot, '.%@velo.local');

SET @op_maint  = (SELECT id_utilisateur FROM utilisateur WHERE email = CONCAT('test.operateur.', @lot, '.1@velo.local'));
SET @op_maint2 = (SELECT id_utilisateur FROM utilisateur WHERE email = CONCAT('test.operateur.', @lot, '.2@velo.local'));
SET @op_reg    = (SELECT id_utilisateur FROM utilisateur WHERE email = CONCAT('test.operateur.', @lot, '.3@velo.local'));

-- -----------------------------------------------------------------------------
--  5. Abonnements et factures d'abonnement
--     10 % sans abonnement, 40 % annuel, 35 % mensuel, 15 % tarif réduit.
--     Un abonnement annuel a commencé il y a 95 à 345 jours, un mensuel il y a 2 à 28 jours
--     (la moitié des mensuels ont en plus un ancien abonnement expiré).
-- -----------------------------------------------------------------------------
UPDATE tmp_test_usager
   SET id_formule = CASE WHEN r_formule < 0.10 THEN NULL
                         WHEN r_formule < 0.50 THEN @f_annuel
                         WHEN r_formule < 0.85 THEN @f_mensuel
                         ELSE @f_reduit END;

UPDATE tmp_test_usager
   SET date_debut = IF(id_formule = @f_mensuel,
                       NOW() - INTERVAL (2 * 1440 + FLOOR(RAND() * 26 * 1440)) MINUTE,
                       NOW() - INTERVAL (95 * 1440 + FLOOR(RAND() * 250 * 1440)) MINUTE)
 WHERE id_formule IS NOT NULL;

-- Anciens abonnements mensuels, expirés
INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
SELECT t.id_utilisateur, @f_mensuel,
       t.date_debut - INTERVAL 40 DAY, t.date_debut - INTERVAL 10 DAY, 'expire', 0
  FROM tmp_test_usager t
 WHERE t.id_formule = @f_mensuel AND t.r_ancien < 0.5;

-- Abonnements en cours (trg_abonnement_bi : un seul actif par usager)
INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
SELECT t.id_utilisateur, t.id_formule, t.date_debut,
       t.date_debut + INTERVAL f.duree_validite_jours DAY, 'actif', t.renouv
  FROM tmp_test_usager t
  JOIN formule f ON f.id_formule = t.id_formule;

-- Compte de démonstration : abonnement annuel commencé il y a 120 jours, s'il n'en a pas
SET @demo = (SELECT u.id_utilisateur FROM utilisateur u
               JOIN usager us ON us.id_utilisateur = u.id_utilisateur
              WHERE u.email = 'usager@velo.local');

INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
SELECT @demo, @f_annuel, NOW() - INTERVAL 120 DAY, NOW() + INTERVAL 245 DAY, 'actif', 0
  FROM DUAL
 WHERE @demo IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM abonnement
                    WHERE id_utilisateur = @demo AND statut = 'actif' AND date_fin > NOW());

-- Une facture par abonnement créé (95 % payées)
INSERT INTO facture (id_abonnement, date_emission, montant_total, statut_paiement)
SELECT a.id_abonnement, a.date_debut, f.prix, IF(RAND() < 0.95, 'payee', 'echouee')
  FROM abonnement a
  JOIN formule f ON f.id_formule = a.id_formule
 WHERE (a.id_utilisateur IN (SELECT id_utilisateur FROM tmp_test_usager) OR a.id_utilisateur = @demo)
   AND NOT EXISTS (SELECT 1 FROM facture x WHERE x.id_abonnement = a.id_abonnement);

-- -----------------------------------------------------------------------------
--  6. Trajets terminés sur les @jours derniers jours
--     Chaque trajet tombe dans la période de validité de son abonnement ; heures de pointe
--     plus chargées, un tiers de trajets en moins le week-end. Le coût est calculé par
--     trg_location_bi (fn_calculer_cout).
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_abo (rn, id_abonnement, jours)
SELECT ROW_NUMBER() OVER (ORDER BY a.id_abonnement), a.id_abonnement,
       LEAST(@jours, DATEDIFF(CURDATE(), DATE(a.date_debut)) - 1)
  FROM abonnement a
 WHERE (a.id_utilisateur IN (SELECT id_utilisateur FROM tmp_test_usager) OR a.id_utilisateur = @demo)
   AND a.statut = 'actif' AND a.date_fin > NOW()
   AND DATEDIFF(CURDATE(), DATE(a.date_debut)) >= 2;
SET @nb_abo = (SELECT COUNT(*) FROM tmp_test_abo);

INSERT INTO tmp_test_tirage (n, r_abo, r_velo, r_dep, r_arr, r_jour, r_we, heure, minute, duree)
SELECT n.n,
       1 + FLOOR(RAND() * @nb_abo),
       1 + FLOOR(RAND() * @nb_velos),
       1 + FLOOR(RAND() * @nb_bornes),
       1 + FLOOR(RAND() * @nb_bornes),
       RAND(), RAND(),
       ELT(1 + FLOOR(RAND() * 24), 7, 8, 8, 8, 8, 9, 9, 10, 11, 12, 12, 13, 14, 15, 16, 17, 17, 17, 18, 18, 18, 19, 20, 22),
       FLOOR(RAND() * 60),
       3 + FLOOR(POW(RAND(), 2.2) * 70) + IF(RAND() < 0.04, 40 + FLOOR(RAND() * 80), 0)
  FROM tmp_test_n n
 WHERE n.n <= @nb_locations AND @nb_abo > 0 AND @nb_velos > 0 AND @nb_bornes > 0;

INSERT INTO location (id_abonnement, id_velo, id_borne_depart, id_borne_arrivee,
                      date_heure_emprunt, date_heure_restitution)
SELECT x.id_abonnement, x.id_velo, x.dep, x.arr, x.emprunt, x.emprunt + INTERVAL x.duree MINUTE
  FROM (SELECT a.id_abonnement, v.id_velo, bd.id_borne AS dep, ba.id_borne AS arr, t.duree, t.r_we,
               TIMESTAMP(CURDATE() - INTERVAL (1 + FLOOR(t.r_jour * a.jours)) DAY, MAKETIME(t.heure, t.minute, 0)) AS emprunt
          FROM tmp_test_tirage t
          JOIN tmp_test_abo   a  ON a.rn  = t.r_abo
          JOIN tmp_test_velo  v  ON v.rn  = t.r_velo
          JOIN tmp_test_borne bd ON bd.rn = t.r_dep
          JOIN tmp_test_borne ba ON ba.rn = t.r_arr) x
 WHERE NOT (DAYOFWEEK(x.emprunt) IN (1, 7) AND x.r_we < 0.35)
   AND x.emprunt + INTERVAL x.duree MINUTE <= NOW()
 ORDER BY x.emprunt;

-- Factures des trajets des mois passés (une par abonnement, émise le 1er du mois courant)
SET @mois = DATE_FORMAT(CURDATE(), '%Y-%m-01');
SET @fact0 = (SELECT COALESCE(MAX(id_facture), 0) FROM facture);

INSERT INTO facture (id_abonnement, date_emission, montant_total, statut_paiement)
SELECT l.id_abonnement, @mois, SUM(l.cout), 'payee'
  FROM location l
  JOIN tmp_test_abo a ON a.id_abonnement = l.id_abonnement
 WHERE l.id_facture IS NULL AND l.cout > 0 AND l.date_heure_restitution < @mois
 GROUP BY l.id_abonnement;

UPDATE location l
  JOIN tmp_test_abo a ON a.id_abonnement = l.id_abonnement
  JOIN facture f ON f.id_abonnement = l.id_abonnement AND f.id_facture > @fact0
   SET l.id_facture = f.id_facture
 WHERE l.id_facture IS NULL AND l.cout > 0 AND l.date_heure_restitution < @mois;

-- -----------------------------------------------------------------------------
--  7. État courant : vélos tirés au hasard parmi les vélos disponibles du lot
--       rang 1 à 5   : en cours de location
--       rang 6 à 11  : signalés, en attente (défectueux)
--       rang 12 à 14 : en atelier, signalement pris en charge
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_choix (rn, id_velo, id_borne)
SELECT ROW_NUMBER() OVER (ORDER BY RAND()), v.id_velo, v.id_borne
  FROM velo v
  JOIN tmp_test_velo tv ON tv.id_velo = v.id_velo
 WHERE v.etat_velo = 'disponible' AND v.id_borne IS NOT NULL;

-- Locations en cours : 5 usagers du lot ayant un abonnement valide (pas le compte de démo)
INSERT INTO tmp_test_actif (rn, id_abonnement)
SELECT ROW_NUMBER() OVER (ORDER BY RAND()), a.id_abonnement
  FROM abonnement a
  JOIN tmp_test_usager t ON t.id_utilisateur = a.id_utilisateur
 WHERE a.statut = 'actif' AND a.date_debut < NOW() - INTERVAL 1 HOUR AND a.date_fin > NOW();

INSERT INTO location (id_abonnement, id_velo, id_borne_depart, date_heure_emprunt)
SELECT a.id_abonnement, c.id_velo, c.id_borne, NOW() - INTERVAL (5 + FLOOR(RAND() * 50)) MINUTE
  FROM tmp_test_actif a
  JOIN tmp_test_choix c ON c.rn = a.rn
 WHERE a.rn <= 5;

UPDATE velo v
  JOIN tmp_test_choix c ON c.id_velo = v.id_velo
  JOIN location l ON l.velo_en_cours = v.id_velo
   SET v.etat_velo = 'en_location', v.id_borne = NULL
 WHERE c.rn <= 5;

-- Signalements ouverts sur des vélos (trg_signalement_ai les passe en « défectueux »)
INSERT INTO signalement (id_utilisateur, id_velo, date_heure, description, statut)
SELECT u.id_utilisateur, c.id_velo, NOW() - INTERVAL (c.rn * 4 + FLOOR(RAND() * 3)) HOUR,
       ELT(1 + FLOOR(RAND() * 8), 'Pneu avant crevé', 'Freins qui ne répondent presque plus',
           'Chaîne qui saute dans les montées', 'Selle cassée, impossible de la régler',
           'Éclairage avant hors service', 'Batterie qui se vide en quelques minutes',
           'Bruit métallique au niveau du pédalier', 'Garde-boue arrière tordu, frotte sur la roue'),
       'ouvert'
  FROM tmp_test_choix c
  JOIN tmp_test_usager u ON u.rn = 1 + MOD(c.rn * 7, @nb_usagers)
 WHERE c.rn BETWEEN 6 AND 14;

-- Trois vélos retirés pour réparation (comme sp_ouvrir_intervention)
INSERT INTO intervention (id_velo, id_operateur, date_retrait, date_debut_reparation, description_travaux)
SELECT c.id_velo, IF(c.rn = 13, @op_maint2, @op_maint), NOW() - INTERVAL (c.rn * 2) HOUR,
       IF(c.rn = 12, NULL, NOW() - INTERVAL (c.rn * 2 - 1) HOUR),
       ELT(c.rn - 11, 'Remplacement de la chambre à air', 'Réglage et changement des patins de frein',
           'Diagnostic batterie et contrôleur')
  FROM tmp_test_choix c
 WHERE c.rn BETWEEN 12 AND 14;

UPDATE velo v
  JOIN tmp_test_choix c ON c.id_velo = v.id_velo
   SET v.etat_velo = 'en_atelier', v.id_borne = NULL
 WHERE c.rn BETWEEN 12 AND 14;

UPDATE signalement s
  JOIN tmp_test_choix c ON c.id_velo = s.id_velo AND c.rn BETWEEN 12 AND 14
  JOIN intervention i ON i.id_velo = s.id_velo AND i.date_remise_circulation IS NULL
   SET s.statut = 'pris_en_charge', s.id_intervention = i.id_intervention
 WHERE s.statut = 'ouvert';

-- Signalements ouverts sur des stations
INSERT INTO signalement (id_utilisateur, id_station, date_heure, description, statut)
SELECT u.id_utilisateur, s.id_station, NOW() - INTERVAL (s.k * 5) HOUR,
       ELT(s.k, 'La borne 3 ne libère pas le vélo', 'Écran de la station illisible au soleil',
           'Plusieurs bornes signalent une erreur de verrouillage'),
       'ouvert'
  FROM tmp_test_station s
  JOIN tmp_test_usager u ON u.rn = 1 + MOD(s.k * 11, @nb_usagers)
 WHERE s.k <= 3;

-- Historique : signalements clos et interventions terminées
INSERT INTO signalement (id_utilisateur, id_velo, date_heure, description, statut)
SELECT u.id_utilisateur, v.id_velo, NOW() - INTERVAL (3 + n.n * 6) DAY - INTERVAL FLOOR(RAND() * 600) MINUTE,
       ELT(1 + MOD(n.n, 6), 'Pneu arrière à plat', 'Sonnette arrachée', 'Béquille cassée',
           'Panier déformé', 'Dérailleur mal réglé', 'Poignée de frein desserrée'),
       'clos'
  FROM tmp_test_n n
  JOIN tmp_test_velo v ON v.rn = 1 + MOD(n.n * 13, @nb_velos)
  JOIN tmp_test_usager u ON u.rn = 1 + MOD(n.n * 3, @nb_usagers)
 WHERE n.n <= 12;

INSERT INTO intervention (id_velo, id_operateur, date_retrait, date_debut_reparation,
                          date_remise_circulation, description_travaux)
SELECT x.id_velo, x.op, x.retrait, x.retrait + INTERVAL 2 HOUR,
       x.retrait + INTERVAL (1 + MOD(x.n, 3)) DAY, x.travaux
  FROM (SELECT v.id_velo, IF(MOD(n.n, 2) = 0, @op_maint, @op_maint2) AS op, n.n,
               NOW() - INTERVAL (5 + n.n * 7) DAY AS retrait,
               ELT(1 + MOD(n.n, 5), 'Changement de pneu', 'Remplacement de la chaîne',
                   'Révision complète', 'Remplacement du câble de frein', 'Mise à jour du contrôleur') AS travaux
          FROM tmp_test_n n
          JOIN tmp_test_velo v ON v.rn = 1 + MOD(n.n * 17, @nb_velos)
         WHERE n.n <= 10) x;

-- -----------------------------------------------------------------------------
--  8. Régulation : 2 véhicules, 6 tournées passées de 4 déplacements
-- -----------------------------------------------------------------------------
INSERT INTO vehicule (immatriculation, capacite_velos)
VALUES (CONCAT('TEST-', @lot, '-1'), 20), (CONCAT('TEST-', @lot, '-2'), 12);
SET @veh = (SELECT id_vehicule FROM vehicule WHERE immatriculation = CONCAT('TEST-', @lot, '-1'));

SET @t0 = (SELECT COALESCE(MAX(id_tournee), 0) FROM tournee);
INSERT INTO tournee (id_operateur, id_vehicule, date_heure_debut, date_heure_fin)
SELECT @op_reg, @veh + MOD(n.n, 2),
       TIMESTAMP(CURDATE() - INTERVAL (n.n * 4) DAY, '07:30:00'),
       TIMESTAMP(CURDATE() - INTERVAL (n.n * 4) DAY, '10:45:00')
  FROM tmp_test_n n
 WHERE n.n <= 6;

INSERT INTO tmp_test_tournee (rn, id_tournee)
SELECT ROW_NUMBER() OVER (ORDER BY id_tournee), id_tournee FROM tournee WHERE id_tournee > @t0;

INSERT INTO ligne_tournee (id_tournee, num_ligne, id_velo, id_station_depart, id_station_arrivee, date_heure_deplacement)
SELECT t.id_tournee, l.n, v.id_velo, sd.id_station, sa.id_station,
       TIMESTAMP(CURDATE() - INTERVAL (t.rn * 4) DAY, '07:30:00') + INTERVAL (l.n * 40) MINUTE
  FROM tmp_test_tournee t
  JOIN tmp_test_n l ON l.n <= 4
  JOIN tmp_test_velo v ON v.rn = 1 + MOD(t.rn * 31 + l.n * 7, @nb_velos)
  JOIN tmp_test_station sd ON sd.k = 1 + MOD(t.rn + l.n, 13)
  JOIN tmp_test_station sa ON sa.k = 1 + MOD(t.rn + l.n + 1 + MOD(l.n * t.rn, 12), 13);

-- -----------------------------------------------------------------------------
--  9. Relevés horaires de remplissage des stations (statistiques)
--     Chaque station oscille autour de son remplissage cible au fil de la journée.
-- -----------------------------------------------------------------------------
INSERT INTO tmp_test_releve (id_station, horodatage, nb_fonct, velos)
SELECT s.id_station,
       TIMESTAMP(CURDATE() - INTERVAL (d.n - 1) DAY, MAKETIME(h.n - 1, 0, 0)),
       s.nb_fonct,
       IF(s.etat = 'en_service',
          ROUND(s.nb_fonct * LEAST(1, GREATEST(0,
                s.remplissage + 0.3 * SIN((h.n - 1 + s.k * 2) * PI() / 12) + (RAND() - 0.5) * 0.15))),
          0)
  FROM tmp_test_station s
  JOIN tmp_test_n d ON d.n <= @jours_releves
  JOIN tmp_test_n h ON h.n <= 24
 WHERE TIMESTAMP(CURDATE() - INTERVAL (d.n - 1) DAY, MAKETIME(h.n - 1, 0, 0)) <= NOW();

INSERT INTO releve_station (id_station, horodatage, nb_velos_mecaniques, nb_velos_electriques, nb_bornes_libres)
SELECT id_station, horodatage, velos - ROUND(velos * 0.35), ROUND(velos * 0.35), nb_fonct - velos
  FROM tmp_test_releve;

COMMIT;

-- -----------------------------------------------------------------------------
--  Résumé du lot, puis nettoyage
-- -----------------------------------------------------------------------------
SELECT @lot                                                                   AS lot,
       (SELECT COUNT(*) FROM tmp_test_station)                                AS stations,
       (SELECT COUNT(*) FROM borne b JOIN tmp_test_station s ON s.id_station = b.id_station) AS bornes,
       @nb_velos                                                              AS velos,
       @nb_usagers                                                            AS usagers,
       (SELECT COUNT(*) FROM location l JOIN tmp_test_velo v ON v.id_velo = l.id_velo)        AS trajets,
       (SELECT COUNT(*) FROM location l JOIN tmp_test_velo v ON v.id_velo = l.id_velo
         WHERE l.date_heure_restitution IS NULL)                              AS en_cours,
       (SELECT COUNT(*) FROM signalement WHERE statut <> 'clos')              AS signalements_ouverts,
       CONCAT('test.usager.', @lot, '.1@velo.local / Demo1234!')              AS exemple_connexion;

DROP TABLE IF EXISTS tmp_test_n, tmp_test_lieu, tmp_test_station, tmp_test_velo, tmp_test_borne,
                     tmp_test_usager, tmp_test_abo, tmp_test_tirage, tmp_test_choix,
                     tmp_test_actif, tmp_test_tournee, tmp_test_releve;
