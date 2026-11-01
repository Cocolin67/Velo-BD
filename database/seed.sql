-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  SEEDING : génération de données factices en masse (jusqu'à plusieurs millions de lignes)
--
--  À exécuter APRÈS schema.sql, triggers.sql et procedures.sql, sur une base VIDE :
--      mysql -u <utilisateur> -p --default-character-set=utf8mb4 < seed.sql
--
--  Utilisation :
--      CALL sp_seed_petit();                       -- 50 000 locations, quelques secondes (tests)
--      CALL sp_seed_demo();                        -- 1 000 000 de locations
--      CALL sp_seed_gros();                        -- 5 000 000 de locations
--      CALL sp_seed_tout(stations, velos, usagers, locations, jours_releves);   -- sur mesure
--      CALL sp_seed_verifier();                    -- contrôles de cohérence
--      CALL sp_seed_compter();                     -- nombre de lignes de chaque table
--      CALL sp_seed_vider('OUI');                  -- repartir d'une base vide (irréversible)
--
--  Principes :
--    - tout est généré par des requêtes ensemblistes (INSERT ... SELECT), par paquets,
--      sans boucle ligne à ligne ;
--    - pendant le chargement, la variable de session @seed_mode = 1 désactive les
--      triggers (voir triggers.sql) et les contrôles de clés étrangères / d'unicité
--      sont suspendus ; les données sont générées cohérentes, puis contrôlées par
--      sp_seed_verifier. Ces réglages sont rétablis à la fin de chaque procédure, même
--      en cas d'erreur ;
--    - la fenêtre d'historique couvre les 360 derniers jours jusqu'à « maintenant » ;
--      chaque vélo suit une chaîne de trajets sans chevauchement (un trajet part de la
--      borne où le précédent s'est terminé), avec heures de pointe, moins de trajets le
--      week-end et en hiver ;
--    - l'état courant (vélos en location, en atelier, défectueux) est cohérent avec
--      les locations, signalements, interventions et historiques ;
--    - les coûts sont calculés avec la même règle que les triggers (fn_cout_formule) ;
--    - les mots de passe sont des hash factices (SHA-256) : ce ne sont pas des comptes
--      utilisables ;
--    - les tables auxiliaires seed_* sont supprimées en fin de chargement
--      (sp_seed_finaliser) ; les procédures peuvent aussi être appelées une par une,
--      dans l'ordre ci-dessous.
--
--  Limites connues (données factices) :
--    - un même usager peut avoir quelques trajets qui se chevauchent (trajets tirés au
--      hasard par usager) : sp_seed_verifier le compte à titre indicatif ;
--    - la capacité des bornes n'est pas simulée dans le temps (un vélo peut arriver sur
--      une borne où un autre vélo est déjà posé) ; seule la position actuelle respecte
--      « une borne, un vélo » ;
--    - les déplacements des tournées de régulation ne sont pas reportés dans
--      l'historique des positions, et les relevés des stations sont synthétiques ;
--    - sp_seed_locations atteint le nombre demandé à moins de 1 % près.
--
--  Ordre des procédures (sp_seed_tout les enchaîne) :
--    sp_seed_preparer         tables auxiliaires (nombres, fenêtre de dates)
--    sp_seed_reference        formules et tranches tarifaires
--    sp_seed_stations         stations et bornes
--    sp_seed_flotte           vélos (position de départ et position finale uniques)
--    sp_seed_utilisateurs     usagers, opérateurs, administrateurs
--    sp_seed_abonnements      abonnements et factures d'abonnement
--    sp_seed_locations        trajets (chaînes par vélo), tickets journée, coûts
--    sp_seed_maintenance      signalements et interventions passés
--    sp_seed_etat_courant     vélos en location / en atelier / défectueux
--    sp_seed_facturation      factures mensuelles des trajets
--    sp_seed_historique       HISTORIQUE_ETAT et HISTORIQUE_POSITION
--    sp_seed_regulation       véhicules, tournées de rééquilibrage et leurs lignes
--    sp_seed_releves          relevés de remplissage des stations
--    sp_seed_verifier, sp_seed_compter, sp_seed_finaliser, sp_seed_vider, sp_seed_nettoyer
-- =============================================================================

USE velo_libre_service;

DELIMITER $$

-- =============================================================================
--  Infrastructure
-- =============================================================================

-- Table de nombres 1..1 000 000 et fenêtre de dates (h0 = début d'historique, h1 = maintenant)
DROP PROCEDURE IF EXISTS sp_seed_preparer$$
CREATE PROCEDURE sp_seed_preparer()
BEGIN
    CREATE TABLE IF NOT EXISTS seed_param (
        id TINYINT UNSIGNED NOT NULL,
        h0 DATETIME NOT NULL,
        h1 DATETIME NOT NULL,
        PRIMARY KEY (id)
    ) ENGINE=InnoDB;
    INSERT IGNORE INTO seed_param (id, h0, h1)
    VALUES (1, TIMESTAMP(CURDATE() - INTERVAL 360 DAY),
               TIMESTAMP(DATE_FORMAT(NOW(), '%Y-%m-%d %H:%i:00')));

    CREATE TABLE IF NOT EXISTS seed_nums (
        n INT UNSIGNED NOT NULL,
        PRIMARY KEY (n)
    ) ENGINE=InnoDB;
    IF (SELECT COUNT(*) FROM seed_nums) = 0 THEN
        INSERT INTO seed_nums (n)
        SELECT u.d + 10 * d1.d + 100 * d2.d + 1000 * d3.d + 10000 * d4.d + 100000 * d5.d + 1
          FROM (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) u,
               (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d1,
               (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d2,
               (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d3,
               (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d4,
               (SELECT 0 d UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4
                UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9) d5;
    END IF;
END$$

-- Supprime les tables auxiliaires seed_*
DROP PROCEDURE IF EXISTS sp_seed_nettoyer$$
CREATE PROCEDURE sp_seed_nettoyer()
BEGIN
    DROP TABLE IF EXISTS seed_chunk, seed_chunk2, seed_chunk3, seed_evt, seed_cout, seed_abo_map,
                         seed_usager, seed_borne, seed_station, seed_velo, seed_op, seed_ct, seed_ticket,
                         seed_nums, seed_param;
END$$

-- Vide TOUTES les tables de l'application (irréversible : confirmation exigée)
DROP PROCEDURE IF EXISTS sp_seed_vider$$
CREATE PROCEDURE sp_seed_vider(IN p_confirmation VARCHAR(3))
BEGIN
    DECLARE v_fk INT DEFAULT @@session.foreign_key_checks;
    IF p_confirmation IS NULL OR p_confirmation <> 'OUI' THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Opération irréversible : appeler sp_seed_vider(''OUI'') pour confirmer';
    END IF;
    SET foreign_key_checks = 0;
    TRUNCATE TABLE ligne_tournee;
    TRUNCATE TABLE tournee;
    TRUNCATE TABLE vehicule;
    TRUNCATE TABLE signalement;
    TRUNCATE TABLE intervention;
    TRUNCATE TABLE location;
    TRUNCATE TABLE facture;
    TRUNCATE TABLE abonnement;
    TRUNCATE TABLE tranche_tarifaire;
    TRUNCATE TABLE formule;
    TRUNCATE TABLE historique_position;
    TRUNCATE TABLE historique_etat;
    TRUNCATE TABLE velo;
    TRUNCATE TABLE releve_station;
    TRUNCATE TABLE borne;
    TRUNCATE TABLE station;
    TRUNCATE TABLE administrateur;
    TRUNCATE TABLE operateur;
    TRUNCATE TABLE usager;
    TRUNCATE TABLE utilisateur;
    SET foreign_key_checks = v_fk;
    CALL sp_seed_nettoyer();
END$$

-- =============================================================================
--  1. Référentiel : formules et tranches tarifaires
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_reference$$
CREATE PROCEDURE sp_seed_reference()
BEGIN
    INSERT IGNORE INTO formule
           (libelle, prix, duree_validite_jours, duree_gratuite_min, supplement_electrique)
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
END$$

-- =============================================================================
--  2. Stations et bornes
--     Les stations sont réparties dans un rectangle de ~13 x 15 km ; les bornes
--     (p_bornes_min à p_bornes_max par station) sont à 99 % fonctionnelles.
--     seed_borne classe les bornes fonctionnelles par proximité du centre
--     (rang 1 = la plus centrale) : les trajets favorisent le centre.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_stations$$
CREATE PROCEDURE sp_seed_stations(
    IN p_nb_stations SMALLINT UNSIGNED,
    IN p_bornes_min  SMALLINT UNSIGNED,
    IN p_bornes_max  SMALLINT UNSIGNED
)
BEGIN
    DECLARE v_base INT DEFAULT 0;
    DECLARE v_max  INT DEFAULT 0;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    IF p_nb_stations < 1 OR p_nb_stations > 5000 OR p_bornes_min < 4 OR p_bornes_max < p_bornes_min THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Paramètres invalides (1 à 5000 stations, au moins 4 bornes, max >= min)';
    END IF;
    CALL sp_seed_preparer();
    SET @seed_mode = 1;

    SELECT COUNT(*), COALESCE(MAX(id_station), 0) INTO v_base, v_max FROM station;

    INSERT INTO station (nom, adresse, latitude, longitude, etat_station)
    SELECT CONCAT('Station ', LPAD(s.n + v_base, 4, '0'), ' - ',
                  ELT(1 + FLOOR(RAND() * 12), 'Gare', 'Mairie', 'Université', 'Hôpital', 'Marché', 'Parc',
                      'Stade', 'Musée', 'Port', 'Place Centrale', 'Bibliothèque', 'Zone d''activités')),
           CONCAT(1 + FLOOR(RAND() * 120), ' ',
                  ELT(1 + FLOOR(RAND() * 4), 'rue', 'avenue', 'boulevard', 'place'), ' ',
                  ELT(1 + FLOOR(RAND() * 15), 'de la République', 'Victor Hugo', 'de la Paix', 'Jean Jaurès',
                      'des Écoles', 'du Général de Gaulle', 'Pasteur', 'de la Gare', 'des Lilas', 'du Moulin',
                      'de Verdun', 'des Tilleuls', 'Gambetta', 'de l''Église', 'des Vignes')),
           ROUND(48.80 + RAND() * 0.12, 6),
           ROUND(2.25 + RAND() * 0.20, 6),
           'en_service'
      FROM seed_nums s
     WHERE s.n <= p_nb_stations;

    DROP TABLE IF EXISTS seed_station;
    CREATE TABLE seed_station (
        id_station INT UNSIGNED NOT NULL,
        nb_bornes  SMALLINT UNSIGNED NOT NULL,
        distance   DOUBLE NOT NULL,
        PRIMARY KEY (id_station)
    ) ENGINE=InnoDB;
    INSERT INTO seed_station (id_station, nb_bornes, distance)
    SELECT id_station,
           p_bornes_min + FLOOR(RAND() * (p_bornes_max - p_bornes_min + 1)),
           SQRT(POW(latitude - 48.86, 2) + POW((longitude - 2.35) * 0.66, 2))
      FROM station
     WHERE id_station > v_max;

    SET foreign_key_checks = 0;
    SET unique_checks = 0;
    INSERT INTO borne (id_station, num_borne, etat_borne)
    SELECT st.id_station, b.n, IF(RAND() < 0.01, 'hors_service', 'fonctionnelle')
      FROM seed_station st
      JOIN seed_nums b ON b.n <= st.nb_bornes;
    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;

    DROP TABLE IF EXISTS seed_borne;
    CREATE TABLE seed_borne (
        rn        INT UNSIGNED NOT NULL,
        id_borne  INT UNSIGNED NOT NULL,
        id_station INT UNSIGNED NOT NULL,
        PRIMARY KEY (rn),
        KEY idx_seed_borne_borne (id_borne)
    ) ENGINE=InnoDB;
    INSERT INTO seed_borne (rn, id_borne, id_station)
    SELECT ROW_NUMBER() OVER (ORDER BY ss.distance, b.id_borne), b.id_borne, b.id_station
      FROM borne b
      JOIN seed_station ss ON ss.id_station = b.id_station
     WHERE b.etat_borne = 'fonctionnelle';

    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  3. Flotte
--     Chaque vélo reçoit deux bornes (chaque série est une permutation, donc sans
--     doublon) : une borne de départ
--     (position au début de l'historique) et une borne finale (position actuelle),
--     ce qui respecte « une borne n'accueille qu'un vélo » à ces deux instants.
--     Les vélos sont créés posés sur leur borne de départ ; sp_seed_locations puis
--     sp_seed_etat_courant les amènent à leur état et à leur position actuels.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_flotte$$
CREATE PROCEDURE sp_seed_flotte(
    IN p_nb_velos  INT UNSIGNED,
    IN p_pct_elec  DECIMAL(3, 2)          -- part de vélos électriques, ex. 0.30
)
BEGIN
    DECLARE v_nb_bornes INT;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF EXISTS (SELECT 1 FROM velo LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La flotte existe déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SELECT COUNT(*) INTO v_nb_bornes FROM borne WHERE etat_borne = 'fonctionnelle';
    IF p_nb_velos < 1 OR p_nb_velos > 500000 OR v_nb_bornes < p_nb_velos * 1.1 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Pas assez de bornes fonctionnelles : prévoir au moins 10 % de bornes de plus que de vélos';
    END IF;
    SET @seed_mode = 1;

    DROP TABLE IF EXISTS seed_velo;
    CREATE TABLE seed_velo (
        rn          INT UNSIGNED NOT NULL,
        id_velo     INT UNSIGNED NULL,
        type_velo   ENUM('mecanique', 'electrique') NOT NULL,
        borne_init  INT UNSIGNED NOT NULL,
        borne_final INT UNSIGNED NOT NULL,
        last_end    DATETIME NULL,
        PRIMARY KEY (rn),
        KEY idx_seed_velo_id (id_velo)
    ) ENGINE=InnoDB;

    INSERT INTO seed_velo (rn, type_velo, borne_init, borne_final)
    SELECT n.n,
           IF(RAND() < p_pct_elec, 'electrique', 'mecanique'),
           a.id_borne,
           b.id_borne
      FROM seed_nums n
      JOIN (SELECT id_borne, ROW_NUMBER() OVER (ORDER BY RAND()) AS rn
              FROM borne WHERE etat_borne = 'fonctionnelle') a ON a.rn = n.n
      JOIN (SELECT id_borne, ROW_NUMBER() OVER (ORDER BY RAND()) AS rn
              FROM borne WHERE etat_borne = 'fonctionnelle') b ON b.rn = n.n
     WHERE n.n <= p_nb_velos;

    INSERT INTO velo (type_velo, date_mise_en_service, etat_velo, niveau_batterie, id_borne)
    SELECT type_velo,
           CURDATE() - INTERVAL (365 + FLOOR(RAND() * 1460)) DAY,
           'disponible',
           IF(type_velo = 'electrique', 20 + FLOOR(RAND() * 81), NULL),
           borne_init
      FROM seed_velo
     ORDER BY rn;

    UPDATE seed_velo s
      JOIN (SELECT id_velo, ROW_NUMBER() OVER (ORDER BY id_velo) AS rn FROM velo) v ON v.rn = s.rn
       SET s.id_velo = v.id_velo;

    SET @seed_mode = v_mode;
END$$

DELIMITER ;
DELIMITER $$

-- =============================================================================
--  4. Utilisateurs : usagers, opérateurs (maintenance / régulation), administrateurs
--     Prénoms et noms sont combinés de façon déterministe (40 x 40) ; l'unicité de
--     l'email est garantie par le numéro. Les mots de passe sont des hash factices.
--     Opérateurs : 1 administrateur pour 20 opérateurs (au moins 1) ; sur les autres,
--     40 % de maintenance et 60 % de régulation. Les administrateurs sont des
--     opérateurs de régulation (un administrateur EST un opérateur).
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_utilisateurs$$
CREATE PROCEDURE sp_seed_utilisateurs(
    IN p_nb_usagers    INT UNSIGNED,
    IN p_nb_operateurs SMALLINT UNSIGNED
)
BEGIN
    DECLARE v_avant INT UNSIGNED DEFAULT 0;
    DECLARE v_apres INT UNSIGNED DEFAULT 0;
    DECLARE v_base  INT UNSIGNED DEFAULT 0;
    DECLARE v_nb_adm INT UNSIGNED;
    DECLARE v_nb_maint INT UNSIGNED;
    DECLARE v_h0 DATETIME;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    IF p_nb_usagers < 1 OR p_nb_usagers > 1000000 OR p_nb_operateurs < 3 OR p_nb_operateurs > 5000 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Paramètres invalides (1 à 1 000 000 usagers, 3 à 5000 opérateurs)';
    END IF;
    CALL sp_seed_preparer();
    SET @seed_mode = 1;
    SELECT h0 INTO v_h0 FROM seed_param WHERE id = 1;
    SELECT COALESCE(MAX(id_utilisateur), 0) INTO v_base FROM utilisateur;

    -- ---- usagers
    SET v_avant = v_base;
    INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash, date_inscription)
    SELECT t.nom, t.prenom,
           CONCAT(LOWER(t.prenom), '.', LOWER(t.nom), '.', t.num, '@exemple.fr'),
           SHA2(CONCAT('motdepasse-seed-', t.num), 256),
           v_h0 - INTERVAL (2 + FLOOR(RAND() * 1100)) DAY
      FROM (SELECT n.n + v_base AS num,
                   ELT(1 + (n.n MOD 40), 'Lea', 'Hugo', 'Emma', 'Louis', 'Chloe', 'Gabriel', 'Jade', 'Arthur',
                       'Louise', 'Jules', 'Alice', 'Adam', 'Lina', 'Raphael', 'Mila', 'Leo', 'Camille', 'Nathan',
                       'Manon', 'Lucas', 'Zoe', 'Ethan', 'Ines', 'Paul', 'Sarah', 'Tom', 'Julie', 'Noah',
                       'Clara', 'Maxime', 'Anna', 'Antoine', 'Eva', 'Theo', 'Lola', 'Victor', 'Nina', 'Enzo',
                       'Rose', 'Samuel') AS prenom,
                   ELT(1 + ((n.n DIV 40) MOD 40), 'Martin', 'Bernard', 'Dubois', 'Thomas', 'Robert', 'Richard',
                       'Petit', 'Durand', 'Leroy', 'Moreau', 'Simon', 'Laurent', 'Lefebvre', 'Michel', 'Garcia',
                       'David', 'Bertrand', 'Roux', 'Vincent', 'Fournier', 'Morel', 'Girard', 'Andre', 'Mercier',
                       'Dupont', 'Lambert', 'Bonnet', 'Francois', 'Martinez', 'Legrand', 'Garnier', 'Faure',
                       'Rousseau', 'Blanc', 'Guerin', 'Muller', 'Henry', 'Roussel', 'Nicolas', 'Perrin') AS nom
              FROM seed_nums n
             WHERE n.n <= p_nb_usagers) t;
    SELECT MAX(id_utilisateur) INTO v_apres FROM utilisateur;

    INSERT INTO usager (id_utilisateur, date_naissance, telephone)
    SELECT id_utilisateur,
           CURDATE() - INTERVAL (6600 + FLOOR(RAND() * 20000)) DAY,
           CONCAT('06', LPAD(FLOOR(RAND() * 100000000), 8, '0'))
      FROM utilisateur
     WHERE id_utilisateur > v_avant AND id_utilisateur <= v_apres;

    -- ---- opérateurs et administrateurs
    SET v_avant = v_apres;
    SET v_nb_adm = GREATEST(1, FLOOR(p_nb_operateurs / 20));
    SET v_nb_maint = FLOOR((p_nb_operateurs - v_nb_adm) * 0.4);
    SELECT COUNT(*) INTO v_base FROM operateur;

    INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash, date_inscription)
    SELECT ELT(1 + (n.n MOD 20), 'Moulin', 'Fabre', 'Giraud', 'Boyer', 'Lopez', 'Gauthier', 'Perez', 'Clement',
               'Morin', 'Lemaire', 'Masson', 'Marchand', 'Duval', 'Denis', 'Dumont', 'Marie', 'Lemoine',
               'Noel', 'Meyer', 'Dufour'),
           ELT(1 + ((n.n DIV 20) MOD 10), 'Pierre', 'Marc', 'Sophie', 'Karim', 'Julien', 'Nadia', 'Olivier',
               'Claire', 'Yann', 'Elodie'),
           IF(n.n <= v_nb_adm, CONCAT('admin', n.n + v_base, '@velos-agglo.fr'),
                               CONCAT('operateur', n.n + v_base, '@velos-agglo.fr')),
           SHA2(CONCAT('motdepasse-seed-op-', n.n + v_base), 256),
           v_h0 - INTERVAL (30 + FLOOR(RAND() * 1500)) DAY
      FROM seed_nums n
     WHERE n.n <= p_nb_operateurs;

    -- (les identifiants auto-incrémentés peuvent présenter des trous : on numérote les lignes)
    INSERT INTO operateur (id_utilisateur, matricule, specialite)
    SELECT x.id_utilisateur,
           CONCAT('OP', LPAD(v_base + x.rk, 5, '0')),
           IF(x.rk <= v_nb_adm, 'regulation',
              IF(x.rk <= v_nb_adm + v_nb_maint, 'maintenance', 'regulation'))
      FROM (SELECT id_utilisateur, ROW_NUMBER() OVER (ORDER BY id_utilisateur) AS rk
              FROM utilisateur WHERE id_utilisateur > v_avant) x;

    INSERT INTO administrateur (id_utilisateur)
    SELECT x.id_utilisateur
      FROM (SELECT id_utilisateur, ROW_NUMBER() OVER (ORDER BY id_utilisateur) AS rk
              FROM utilisateur WHERE id_utilisateur > v_avant) x
     WHERE x.rk <= v_nb_adm;

    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  5. Abonnements et factures d'abonnement
--     Profils (selon le rang de l'usager) : 45 % annuel, 10 % tarif réduit,
--     30 % mensuel, 15 % ticket journée.
--       - annuel / réduit : 1 abonnement couvrant toute la fenêtre d'historique ;
--       - mensuel : 13 abonnements consécutifs de 30 jours (le dernier est en cours) ;
--       - journée : les tickets sont créés plus tard, à partir des trajets
--         (sp_seed_locations), un ticket par usager et par jour d'utilisation.
--     seed_usager et seed_abo_map servent aux procédures suivantes pour retrouver
--     l'abonnement valide d'un usager à une date donnée.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_abonnements$$
CREATE PROCEDURE sp_seed_abonnements()
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    CALL sp_seed_reference();
    IF EXISTS (SELECT 1 FROM abonnement LIMIT 1) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Des abonnements existent déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SET @seed_mode = 1;
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;

    DROP TABLE IF EXISTS seed_usager;
    CREATE TABLE seed_usager (
        rn             INT UNSIGNED NOT NULL,
        id_utilisateur INT UNSIGNED NOT NULL,
        profil         ENUM('annuel', 'reduit', 'mensuel', 'journee') NOT NULL DEFAULT 'annuel',
        rn_cont        INT UNSIGNED NULL,      -- rang parmi les usagers à abonnement continu
        rn_casu        INT UNSIGNED NULL,      -- rang parmi les usagers « ticket journée »
        PRIMARY KEY (rn),
        KEY idx_seed_usager_cont (rn_cont),
        KEY idx_seed_usager_casu (rn_casu)
    ) ENGINE=InnoDB;

    INSERT INTO seed_usager (rn, id_utilisateur)
    SELECT ROW_NUMBER() OVER (ORDER BY id_utilisateur), id_utilisateur FROM usager;

    UPDATE seed_usager
       SET profil = CASE WHEN rn MOD 100 < 45 THEN 'annuel'
                         WHEN rn MOD 100 < 55 THEN 'reduit'
                         WHEN rn MOD 100 < 85 THEN 'mensuel'
                         ELSE 'journee' END;

    UPDATE seed_usager s
      JOIN (SELECT rn, ROW_NUMBER() OVER (ORDER BY rn) AS c FROM seed_usager WHERE profil <> 'journee') x
        ON x.rn = s.rn
       SET s.rn_cont = x.c;
    UPDATE seed_usager s
      JOIN (SELECT rn, ROW_NUMBER() OVER (ORDER BY rn) AS c FROM seed_usager WHERE profil = 'journee') x
        ON x.rn = s.rn
       SET s.rn_casu = x.c;

    -- annuel et tarif réduit : un abonnement qui couvre toute la fenêtre
    INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
    SELECT s.id_utilisateur,
           IF(s.profil = 'annuel', fa.id_formule, fr.id_formule),
           v_h0 - INTERVAL 1 DAY,
           v_h0 - INTERVAL 1 DAY + INTERVAL 365 DAY,
           'actif',
           (s.rn MOD 5) < 3
      FROM seed_usager s
      JOIN formule fa ON fa.libelle = 'Abonnement annuel'
      JOIN formule fr ON fr.libelle = 'Tarif réduit'
     WHERE s.profil IN ('annuel', 'reduit');

    -- mensuel : 13 périodes de 30 jours consécutives
    INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
    SELECT s.id_utilisateur,
           fm.id_formule,
           v_h0 - INTERVAL 1 DAY + INTERVAL (30 * (n.n - 1)) DAY,
           v_h0 - INTERVAL 1 DAY + INTERVAL (30 * n.n) DAY,
           IF(v_h0 - INTERVAL 1 DAY + INTERVAL (30 * n.n) DAY <= v_h1, 'expire', 'actif'),
           (s.rn MOD 5) < 3
      FROM seed_usager s
      JOIN formule fm ON fm.libelle = 'Abonnement mensuel'
      JOIN seed_nums n ON n.n <= 13
     WHERE s.profil = 'mensuel';

    -- correspondance (usager, numéro de période) -> abonnement
    DROP TABLE IF EXISTS seed_abo_map;
    CREATE TABLE seed_abo_map (
        rn            INT UNSIGNED NOT NULL,
        k             TINYINT UNSIGNED NOT NULL,
        id_abonnement INT UNSIGNED NOT NULL,
        id_formule    INT UNSIGNED NOT NULL,
        PRIMARY KEY (rn, k)
    ) ENGINE=InnoDB;
    INSERT INTO seed_abo_map (rn, k, id_abonnement, id_formule)
    SELECT s.rn,
           TIMESTAMPDIFF(DAY, v_h0 - INTERVAL 1 DAY, a.date_debut) DIV 30,
           a.id_abonnement,
           a.id_formule
      FROM seed_usager s
      JOIN abonnement a ON a.id_utilisateur = s.id_utilisateur
     WHERE s.profil <> 'journee';

    -- une facture par abonnement, émise à son début (payée dans la quasi-totalité des cas)
    INSERT INTO facture (id_abonnement, date_emission, montant_total, statut_paiement)
    SELECT a.id_abonnement, a.date_debut, f.prix,
           IF(RAND() < 0.985, 'payee', IF(RAND() < 0.67, 'echouee', 'remboursee'))
      FROM abonnement a
      JOIN formule f ON f.id_formule = a.id_formule;

    SET @seed_mode = v_mode;
END$$

DELIMITER ;
DELIMITER $$

-- =============================================================================
--  5. Locations
--     sp_seed_locations(p_nb_locations)
--     Génère l'historique des trajets, vélo par vélo, par paquets de vélos :
--       1. quota de trajets par vélo (60 % à 140 % de la moyenne) ;
--       2. candidats sur l'année avec heures de pointe (8 h, 12 h, 18 h), moins de
--          trajets le week-end et en hiver, durées à queue lourde ;
--       3. suppression des chevauchements d'un même vélo (fonctions de fenêtre),
--          puis réduction au quota ;
--       4. chaînage des positions : un trajet part de la borne d'arrivée du
--          précédent, le premier de la borne de départ du vélo, le dernier arrive
--          à sa borne finale ;
--       5. attribution d'un abonnement valide (92 % abonnés, 8 % tickets journée
--          créés et facturés à la volée) ;
--       6. coût selon la grille tarifaire (seed_cout, calculée avec fn_cout_formule).
--     Le nombre obtenu est très proche de p_nb_locations (quelques vélos peuvent
--     en avoir moins si l'année est saturée ; limite : 2 500 trajets par vélo).
--     Les locations sont créées terminées ; les locations en cours sont ajoutées
--     par sp_seed_etat_courant.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_locations$$
CREATE PROCEDURE sp_seed_locations(
    IN p_nb_locations BIGINT UNSIGNED
)
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_nb_jours INT;
    DECLARE v_nb_velos INT UNSIGNED;
    DECLARE v_nb_borne INT UNSIGNED;
    DECLARE v_c  INT UNSIGNED;          -- usagers à abonnement continu
    DECLARE v_cc INT UNSIGNED;          -- usagers « ticket journée »
    DECLARE v_f_ticket INT UNSIGNED;
    DECLARE v_avg DOUBLE;
    DECLARE v_taille INT UNSIGNED;
    DECLARE v_lo INT UNSIGNED DEFAULT 1;
    DECLARE v_hi INT UNSIGNED;
    DECLARE v_before INT UNSIGNED;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    SELECT COUNT(*) INTO v_nb_velos FROM seed_velo;
    SELECT COUNT(*) INTO v_nb_borne FROM seed_borne;
    SELECT COALESCE(MAX(rn_cont), 0), COALESCE(MAX(rn_casu), 0) INTO v_c, v_cc FROM seed_usager;
    IF v_nb_velos = 0 OR v_c = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Appeler sp_seed_stations, sp_seed_flotte, sp_seed_utilisateurs et sp_seed_abonnements d''abord';
    END IF;
    IF EXISTS (SELECT 1 FROM location LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Des locations existent déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    IF p_nb_locations < 1 OR p_nb_locations > v_nb_velos * 2500 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Nombre de locations invalide (1 à 2500 par vélo)';
    END IF;
    SELECT id_formule INTO v_f_ticket FROM formule WHERE libelle = 'Ticket journée';
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;
    SET v_nb_jours = TIMESTAMPDIFF(DAY, v_h0, v_h1);
    SET v_avg = p_nb_locations / v_nb_velos;
    SET v_taille = GREATEST(1, FLOOR(300000 / (v_avg * 1.4 * 2 + 2)));
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    -- grille de coût : (formule, type de vélo, durée en minutes) -> coût
    DROP TABLE IF EXISTS seed_cout;
    CREATE TABLE seed_cout (
        id_formule INT UNSIGNED NOT NULL,
        type_velo  ENUM('mecanique', 'electrique') NOT NULL,
        duree_min  SMALLINT UNSIGNED NOT NULL,
        cout       DECIMAL(8, 2) NOT NULL,
        PRIMARY KEY (id_formule, type_velo, duree_min)
    ) ENGINE=InnoDB;
    INSERT INTO seed_cout (id_formule, type_velo, duree_min, cout)
    SELECT f.id_formule, t.type_velo, n.n, fn_cout_formule(f.id_formule, t.type_velo, n.n)
      FROM formule f
      JOIN (SELECT 'mecanique' AS type_velo UNION ALL SELECT 'electrique') t
      JOIN seed_nums n ON n.n <= 720;

    -- tickets journée déjà créés : (usager occasionnel, jour) -> abonnement
    DROP TABLE IF EXISTS seed_ticket;
    CREATE TABLE seed_ticket (
        rn_casu       INT UNSIGNED NOT NULL,
        jour          DATE NOT NULL,
        id_abonnement INT UNSIGNED NOT NULL,
        PRIMARY KEY (rn_casu, jour)
    ) ENGINE=InnoDB;

    -- tables de travail d'un paquet de vélos
    DROP TABLE IF EXISTS seed_chunk, seed_chunk2, seed_chunk3, seed_ct, seed_evt;
    CREATE TABLE seed_chunk (
        rn          INT UNSIGNED NOT NULL,
        id_velo     INT UNSIGNED NOT NULL,
        type_velo   ENUM('mecanique', 'electrique') NOT NULL,
        borne_init  INT UNSIGNED NOT NULL,
        borne_final INT UNSIGNED NOT NULL,
        quota       INT UNSIGNED NOT NULL,
        cand        INT UNSIGNED NOT NULL DEFAULT 0,
        PRIMARY KEY (rn)
    ) ENGINE=InnoDB;
    CREATE TABLE seed_chunk2 (
        id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        rn  INT UNSIGNED NOT NULL,
        d   SMALLINT UNSIGNED NOT NULL,
        r1  DOUBLE NOT NULL,
        g   DOUBLE NOT NULL,
        u2  DOUBLE NOT NULL,
        u3  DOUBLE NOT NULL,
        r4  DOUBLE NOT NULL,
        u1  DOUBLE NOT NULL,
        dur SMALLINT UNSIGNED NULL,
        t0  DATETIME NULL,
        t1  DATETIME NULL,
        PRIMARY KEY (id)
    ) ENGINE=InnoDB;
    CREATE TABLE seed_chunk3 (
        id  BIGINT UNSIGNED NOT NULL AUTO_INCREMENT,
        rn  INT UNSIGNED NOT NULL,
        t0  DATETIME NOT NULL,
        t1  DATETIME NOT NULL,
        dur SMALLINT UNSIGNED NOT NULL,
        mx  DATETIME NULL,
        PRIMARY KEY (id)
    ) ENGINE=InnoDB;
    CREATE TABLE seed_ct (
        rn  INT UNSIGNED NOT NULL,
        t0  DATETIME NOT NULL,
        t1  DATETIME NOT NULL,
        dur SMALLINT UNSIGNED NOT NULL,
        PRIMARY KEY (rn, t0)
    ) ENGINE=InnoDB;
    CREATE TABLE seed_evt (
        rn         INT UNSIGNED NOT NULL,
        seq        INT UNSIGNED NOT NULL,
        nb         INT UNSIGNED NOT NULL,
        t0         DATETIME NOT NULL,
        t1         DATETIME NOT NULL,
        dur        SMALLINT UNSIGNED NOT NULL,
        arr_rn     INT UNSIGNED NULL,
        dep        INT UNSIGNED NULL,
        arr        INT UNSIGNED NULL,
        casu       TINYINT NOT NULL DEFAULT 0,
        u          INT UNSIGNED NULL,
        id_abo     INT UNSIGNED NULL,
        id_formule INT UNSIGNED NULL,
        PRIMARY KEY (rn, seq),
        KEY idx_seed_evt_u (casu, u)
    ) ENGINE=InnoDB;

    WHILE v_lo <= v_nb_velos DO
        SET v_hi = LEAST(v_nb_velos, v_lo + v_taille - 1);
        TRUNCATE TABLE seed_chunk;
        TRUNCATE TABLE seed_chunk2;
        TRUNCATE TABLE seed_chunk3;
        TRUNCATE TABLE seed_ct;
        TRUNCATE TABLE seed_evt;

        -- 1. vélos du paquet et quotas
        INSERT INTO seed_chunk (rn, id_velo, type_velo, borne_init, borne_final, quota)
        SELECT rn, id_velo, type_velo, borne_init, borne_final,
               ROUND(v_avg * (0.6 + 0.8 * RAND()))
          FROM seed_velo
         WHERE rn BETWEEN v_lo AND v_hi;
        UPDATE seed_chunk SET cand = quota * 2 + 2;

        -- 2. candidats : jour, heure (mélange de pics gaussiens) et durée
        INSERT INTO seed_chunk2 (rn, d, r1, g, u2, u3, r4, u1)
        SELECT c.rn, FLOOR(RAND() * v_nb_jours), RAND(),
               SQRT(-2 * LN(1 - RAND())) * COS(6.283185307 * RAND()),
               RAND(), RAND(), RAND(), RAND()
          FROM seed_chunk c
          JOIN seed_nums n ON n.n <= c.cand;
        UPDATE seed_chunk2
           SET dur = FLOOR(LEAST(720, IF(r4 < 0.03, 60 + (r4 / 0.03) * 600, 3 + -LN(1 - r4 * 0.999) * 14))),
               t0  = v_h0 + INTERVAL d DAY
                     + INTERVAL FLOOR(LEAST(1439, GREATEST(0,
                           CASE WHEN r1 < 0.27 THEN 495 + 55 * g
                                WHEN r1 < 0.57 THEN 1065 + 70 * g
                                WHEN r1 < 0.70 THEN 735 + 50 * g
                                ELSE 360 + u2 * 1000 END))) MINUTE;
        UPDATE seed_chunk2 SET t1 = t0 + INTERVAL dur MINUTE;
        -- moins de trajets le week-end et en hiver ; rien après « maintenant - 5 min »
        DELETE FROM seed_chunk2
         WHERE (WEEKDAY(t0) >= 5 AND u1 < 0.35)
            OR (MONTH(t0) IN (12, 1, 2) AND u3 < 0.35)
            OR t1 > v_h1 - INTERVAL 5 MINUTE;

        -- 3. pas de chevauchement pour un même vélo, puis réduction au quota
        INSERT INTO seed_chunk3 (rn, t0, t1, dur, mx)
        SELECT rn, t0, t1, dur,
               MAX(t1) OVER (PARTITION BY rn ORDER BY t0, id
                             ROWS BETWEEN UNBOUNDED PRECEDING AND 1 PRECEDING)
          FROM seed_chunk2;
        DELETE FROM seed_chunk3 WHERE mx IS NOT NULL AND t0 < mx + INTERVAL 2 MINUTE;

        INSERT INTO seed_ct (rn, t0, t1, dur)
        SELECT x.rn, x.t0, x.t1, x.dur
          FROM (SELECT rn, t0, t1, dur,
                       ROW_NUMBER() OVER (PARTITION BY rn ORDER BY RAND()) AS rr
                  FROM seed_chunk3) x
          JOIN seed_chunk b ON b.rn = x.rn
         WHERE x.rr <= b.quota;

        -- 4. chaînage des positions
        INSERT INTO seed_evt (rn, seq, nb, t0, t1, dur)
        SELECT rn,
               ROW_NUMBER() OVER (PARTITION BY rn ORDER BY t0),
               COUNT(*)     OVER (PARTITION BY rn),
               t0, t1, dur
          FROM seed_ct;
        -- arrivée : 70 % pondérée vers le centre, 30 % uniforme
        UPDATE seed_evt
           SET arr_rn = LEAST(v_nb_borne, 1 + FLOOR(v_nb_borne * IF(RAND() < 0.7, POW(RAND(), 1.6), RAND())));
        UPDATE seed_evt e
          JOIN seed_borne sb ON sb.rn = e.arr_rn
           SET e.arr = sb.id_borne;
        UPDATE seed_evt e
          JOIN seed_chunk b ON b.rn = e.rn
           SET e.arr = b.borne_final
         WHERE e.seq = e.nb;
        UPDATE seed_evt e
          JOIN seed_chunk b ON b.rn = e.rn
          LEFT JOIN seed_evt p ON p.rn = e.rn AND p.seq = e.seq - 1
           SET e.dep = IF(e.seq = 1, b.borne_init, p.arr);

        -- 5. usagers et abonnements
        UPDATE seed_evt SET casu = IF(v_cc > 0 AND RAND() < 0.08, 1, 0);
        UPDATE seed_evt SET u = IF(casu = 1, 1 + FLOOR(RAND() * v_cc), 1 + FLOOR(RAND() * v_c));
        UPDATE seed_evt e
          STRAIGHT_JOIN seed_usager su ON su.rn_cont = e.u
          STRAIGHT_JOIN seed_abo_map m ON m.rn = su.rn
                             AND m.k = IF(su.profil = 'mensuel',
                                          LEAST(12, TIMESTAMPDIFF(DAY, v_h0 - INTERVAL 1 DAY, e.t0) DIV 30), 0)
           SET e.id_abo = m.id_abonnement, e.id_formule = m.id_formule
         WHERE e.casu = 0;

        IF v_cc > 0 THEN
            SELECT COALESCE(MAX(id_abonnement), 0) INTO v_before FROM abonnement;
            INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, statut, renouvellement_auto)
            SELECT su.id_utilisateur, v_f_ticket, TIMESTAMP(x.jour), TIMESTAMP(x.jour) + INTERVAL 1 DAY,
                   IF(TIMESTAMP(x.jour) + INTERVAL 1 DAY <= v_h1, 'expire', 'actif'), FALSE
              FROM (SELECT DISTINCT u, DATE(t0) AS jour FROM seed_evt WHERE casu = 1) x
              JOIN seed_usager su ON su.rn_casu = x.u
              LEFT JOIN seed_ticket k ON k.rn_casu = x.u AND k.jour = x.jour
             WHERE k.rn_casu IS NULL;
            INSERT INTO seed_ticket (rn_casu, jour, id_abonnement)
            SELECT su.rn_casu, DATE(a.date_debut), a.id_abonnement
              FROM abonnement a
              JOIN seed_usager su ON su.id_utilisateur = a.id_utilisateur
             WHERE a.id_abonnement > v_before;
            INSERT INTO facture (id_abonnement, date_emission, montant_total, statut_paiement)
            SELECT a.id_abonnement, a.date_debut, f.prix, IF(RAND() < 0.985, 'payee', 'echouee')
              FROM abonnement a
              JOIN formule f ON f.id_formule = a.id_formule
             WHERE a.id_abonnement > v_before;
            UPDATE seed_evt e
              JOIN seed_ticket k ON k.rn_casu = e.u AND k.jour = DATE(e.t0)
               SET e.id_abo = k.id_abonnement, e.id_formule = v_f_ticket
             WHERE e.casu = 1;
        END IF;

        -- 6. insertion des locations (coût tiré de la grille)
        INSERT INTO location (id_abonnement, id_velo, id_borne_depart, id_borne_arrivee,
                              date_heure_emprunt, date_heure_restitution, cout)
        SELECT e.id_abo, b.id_velo, e.dep, e.arr, e.t0, e.t1, c.cout
          FROM seed_evt e
          JOIN seed_chunk b ON b.rn = e.rn
          JOIN seed_cout c ON c.id_formule = e.id_formule AND c.type_velo = b.type_velo AND c.duree_min = e.dur
         ORDER BY e.t0;

        UPDATE seed_velo s
          JOIN (SELECT rn, MAX(t1) AS m FROM seed_ct GROUP BY rn) x ON x.rn = s.rn
           SET s.last_end = x.m;

        SET v_lo = v_hi + 1;
    END WHILE;

    -- un vélo sans trajet reste sur sa borne finale pendant toute la période
    UPDATE seed_velo SET borne_init = borne_final WHERE last_end IS NULL;

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

DELIMITER ;
DELIMITER $$

-- =============================================================================
--  6. Maintenance et signalements passés
--     sp_seed_maintenance(p_nb_interventions)
--     Choisit des fins de trajet au hasard (suivies d'au moins 2 jours sans
--     emprunt) : l'usager signale le vélo, un opérateur de maintenance le retire,
--     le répare, puis le remet en circulation sur la même borne. Ajoute aussi
--     des signalements sur des stations (un tiers du nombre d'interventions).
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_maintenance$$
CREATE PROCEDURE sp_seed_maintenance(
    IN p_nb_interventions INT UNSIGNED
)
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_nl BIGINT UNSIGNED;
    DECLARE v_pas BIGINT UNSIGNED;
    DECLARE v_nop INT UNSIGNED;
    DECLARE v_nu  INT UNSIGNED;
    DECLARE v_nst INT UNSIGNED;
    DECLARE v_nsig INT UNSIGNED;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF EXISTS (SELECT 1 FROM intervention LIMIT 1) OR EXISTS (SELECT 1 FROM signalement LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Des interventions existent déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SELECT COUNT(*) INTO v_nl FROM location;
    IF v_nl = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appeler sp_seed_locations d''abord';
    END IF;
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    DROP TABLE IF EXISTS seed_op;
    CREATE TABLE seed_op (
        rn INT UNSIGNED NOT NULL,
        id_utilisateur INT UNSIGNED NOT NULL,
        PRIMARY KEY (rn)
    ) ENGINE=InnoDB;
    INSERT INTO seed_op (rn, id_utilisateur)
    SELECT ROW_NUMBER() OVER (ORDER BY id_utilisateur), id_utilisateur
      FROM operateur WHERE specialite = 'maintenance';
    SELECT COUNT(*) INTO v_nop FROM seed_op;
    IF v_nop = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aucun opérateur de maintenance : appeler sp_seed_utilisateurs d''abord';
    END IF;

    -- fins de trajet candidates (échantillon régulier de la table)
    SET v_pas = GREATEST(1, FLOOR(v_nl / (p_nb_interventions * 2)));
    DROP TABLE IF EXISTS seed_chunk;
    CREATE TABLE seed_chunk (
        id_location BIGINT UNSIGNED NOT NULL,
        id_velo     INT UNSIGNED NOT NULL,
        id_abonnement INT UNSIGNED NOT NULL,
        retrait     DATETIME NOT NULL,
        suivant     DATETIME NULL,
        rr          INT UNSIGNED NULL,
        m1          INT NOT NULL DEFAULT 0,
        m2          INT NOT NULL DEFAULT 0,
        PRIMARY KEY (id_location)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk (id_location, id_velo, id_abonnement, retrait, suivant)
    SELECT l.id_location, l.id_velo, l.id_abonnement,
           l.date_heure_restitution + INTERVAL 10 MINUTE,
           (SELECT MIN(n.date_heure_emprunt) FROM location n
             WHERE n.id_velo = l.id_velo AND n.date_heure_emprunt > l.date_heure_restitution)
      FROM location l
     WHERE l.id_location MOD v_pas = 0
       AND l.date_heure_restitution IS NOT NULL;
    DELETE FROM seed_chunk WHERE suivant IS NULL OR suivant < retrait + INTERVAL 2 DAY;
    DROP TABLE IF EXISTS seed_chunk2;
    CREATE TABLE seed_chunk2 LIKE seed_chunk;
    INSERT INTO seed_chunk2 (id_location, id_velo, id_abonnement, retrait, suivant, rr, m1, m2)
    SELECT id_location, id_velo, id_abonnement, retrait, suivant,
           ROW_NUMBER() OVER (ORDER BY RAND()),
           30 + FLOOR(RAND() * 720), 60 + FLOOR(RAND() * 1500)
      FROM seed_chunk;
    DELETE FROM seed_chunk2 WHERE rr > p_nb_interventions;

    INSERT INTO intervention (id_velo, id_operateur, date_retrait, date_debut_reparation,
                              date_remise_circulation, description_travaux)
    SELECT c.id_velo, o.id_utilisateur, c.retrait,
           c.retrait + INTERVAL c.m1 MINUTE,
           c.retrait + INTERVAL (c.m1 + c.m2) MINUTE,
           ELT(1 + FLOOR(RAND() * 8), 'Remplacement de la chambre à air', 'Réglage des freins',
               'Remplacement de la chaîne', 'Changement de la selle', 'Remplacement du pneu',
               'Réparation du dérailleur', 'Remplacement de la batterie', 'Réglage de l''éclairage')
      FROM seed_chunk2 c
      JOIN seed_op o ON o.rn = 1 + (c.rr MOD v_nop);

    -- signalements des vélos (l'auteur est l'usager du dernier trajet)
    INSERT INTO signalement (id_utilisateur, id_velo, id_station, id_intervention, date_heure, description, statut)
    SELECT a.id_utilisateur, c.id_velo, NULL, i.id_intervention, c.retrait - INTERVAL 9 MINUTE,
           ELT(1 + FLOOR(RAND() * 8), 'Freins qui frottent', 'Pneu crevé', 'Chaîne qui saute', 'Selle cassée',
               'Assistance électrique en panne', 'Éclairage défaillant', 'Garde-boue cassé', 'Pédale cassée'),
           'clos'
      FROM seed_chunk2 c
      JOIN abonnement a   ON a.id_abonnement = c.id_abonnement
      JOIN intervention i ON i.id_velo = c.id_velo AND i.date_retrait = c.retrait;

    -- signalements sur les stations
    SET v_nsig = GREATEST(1, FLOOR(p_nb_interventions / 3));
    SELECT COUNT(*) INTO v_nu  FROM seed_usager;
    SELECT COUNT(*) INTO v_nst FROM station;
    DROP TABLE IF EXISTS seed_chunk3;
    CREATE TABLE seed_chunk3 (
        n INT UNSIGNED NOT NULL,
        ru INT UNSIGNED NOT NULL,
        rs INT UNSIGNED NOT NULL,
        d  DATETIME NOT NULL,
        PRIMARY KEY (n)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk3 (n, ru, rs, d)
    SELECT n.n, 1 + FLOOR(RAND() * v_nu), 1 + FLOOR(RAND() * v_nst),
           v_h0 + INTERVAL FLOOR(RAND() * TIMESTAMPDIFF(MINUTE, v_h0, v_h1 - INTERVAL 1 HOUR)) MINUTE
      FROM seed_nums n WHERE n.n <= v_nsig;
    INSERT INTO signalement (id_utilisateur, id_velo, id_station, id_intervention, date_heure, description, statut)
    SELECT su.id_utilisateur, NULL, st.id_station, NULL, c.d,
           ELT(1 + FLOOR(RAND() * 6), 'Borne qui ne verrouille pas', 'Écran de la station éteint', 'Station sale',
               'Vélo mal rangé', 'Borne hors service', 'Panneau d''information endommagé'),
           IF(c.d < v_h1 - INTERVAL 7 DAY, 'clos', 'ouvert')
      FROM seed_chunk3 c
      JOIN seed_usager su ON su.rn = c.ru
      JOIN (SELECT id_station, ROW_NUMBER() OVER (ORDER BY id_station) AS rn FROM station) st ON st.rn = c.rs;

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  7. État courant du réseau
--     sp_seed_etat_courant()
--     Amène chaque vélo à son état actuel : posé sur sa borne finale (disponible),
--     en location (≈ 0,8 % : location en cours), en atelier (≈ 1,2 % : intervention
--     ouverte) ou défectueux (≈ 2 % : signalement ouvert). Les vélos en location ou
--     en atelier n'ont pas de borne.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_etat_courant$$
CREATE PROCEDURE sp_seed_etat_courant()
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_nv INT UNSIGNED;
    DECLARE v_nu INT UNSIGNED;
    DECLARE v_c  INT UNSIGNED;
    DECLARE v_nop INT UNSIGNED;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    SELECT COUNT(*) INTO v_nv FROM seed_velo;
    SELECT COUNT(*), COALESCE(MAX(rn_cont), 0) INTO v_nu, v_c FROM seed_usager;
    IF v_nv = 0 OR NOT EXISTS (SELECT 1 FROM location LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appeler sp_seed_locations d''abord';
    END IF;
    IF EXISTS (SELECT 1 FROM location WHERE date_heure_restitution IS NULL LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'L''état courant est déjà en place';
    END IF;
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    DROP TABLE IF EXISTS seed_op;
    CREATE TABLE seed_op (rn INT UNSIGNED NOT NULL, id_utilisateur INT UNSIGNED NOT NULL, PRIMARY KEY (rn)) ENGINE=InnoDB;
    INSERT INTO seed_op (rn, id_utilisateur)
    SELECT ROW_NUMBER() OVER (ORDER BY id_utilisateur), id_utilisateur FROM operateur WHERE specialite = 'maintenance';
    SELECT COUNT(*) INTO v_nop FROM seed_op;

    -- sélection des vélos : location (1), atelier (2), défectueux (3)
    DROP TABLE IF EXISTS seed_chunk;
    CREATE TABLE seed_chunk (
        rn      INT UNSIGNED NOT NULL,
        id_velo INT UNSIGNED NOT NULL,
        genre   TINYINT NOT NULL,
        fin     DATETIME NOT NULL,      -- fin du dernier trajet (ou début de l'historique)
        rr      INT UNSIGNED NOT NULL,
        ru      INT UNSIGNED NOT NULL,  -- usager tiré au hasard (signalement)
        m1      INT NOT NULL,
        t       DATETIME NULL,
        PRIMARY KEY (rn),
        KEY idx_seed_chunk_genre (genre, rr)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk (rn, id_velo, genre, fin, rr, ru, m1)
    SELECT rn, id_velo, 1, COALESCE(last_end, v_h0),
           ROW_NUMBER() OVER (ORDER BY RAND()), 1 + FLOOR(RAND() * v_nu), 1 + FLOOR(RAND() * 55)
      FROM seed_velo
     WHERE COALESCE(last_end, v_h0) <= v_h1 - INTERVAL 90 MINUTE;
    DELETE FROM seed_chunk WHERE rr > CEIL(v_nv * 0.008) OR rr > v_c;

    INSERT INTO seed_chunk (rn, id_velo, genre, fin, rr, ru, m1)
    SELECT x.rn, x.id_velo, 2, x.fin, ROW_NUMBER() OVER (ORDER BY RAND()), 1 + FLOOR(RAND() * v_nu),
           60 + FLOOR(RAND() * 2800)
      FROM (SELECT s.rn, s.id_velo, COALESCE(s.last_end, v_h0) AS fin FROM seed_velo s
             WHERE COALESCE(s.last_end, v_h0) <= v_h1 - INTERVAL 3 DAY
               AND s.rn NOT IN (SELECT rn FROM seed_chunk)) x
     LIMIT 100000000;
    DELETE FROM seed_chunk WHERE genre = 2 AND rr > CEIL(v_nv * 0.012);

    INSERT INTO seed_chunk (rn, id_velo, genre, fin, rr, ru, m1)
    SELECT x.rn, x.id_velo, 3, x.fin, ROW_NUMBER() OVER (ORDER BY RAND()), 1 + FLOOR(RAND() * v_nu),
           30 + FLOOR(RAND() * 1400)
      FROM (SELECT s.rn, s.id_velo, COALESCE(s.last_end, v_h0) AS fin FROM seed_velo s
             WHERE COALESCE(s.last_end, v_h0) <= v_h1 - INTERVAL 1 DAY
               AND s.rn NOT IN (SELECT rn FROM seed_chunk)) x
     LIMIT 100000000;
    DELETE FROM seed_chunk WHERE genre = 3 AND rr > CEIL(v_nv * 0.02);

    -- (1) locations en cours : un usager distinct par vélo
    UPDATE seed_chunk SET t = v_h1 - INTERVAL m1 MINUTE WHERE genre = 1;
    INSERT INTO location (id_abonnement, id_velo, id_borne_depart, id_borne_arrivee,
                          date_heure_emprunt, date_heure_restitution, cout)
    SELECT m.id_abonnement, c.id_velo, s.borne_final, NULL, c.t, NULL, NULL
      FROM seed_chunk c
      JOIN seed_velo s    ON s.rn = c.rn
      JOIN seed_usager su ON su.rn_cont = c.rr
      JOIN seed_abo_map m ON m.rn = su.rn
                         AND m.k = IF(su.profil = 'mensuel',
                                      LEAST(12, TIMESTAMPDIFF(DAY, v_h0 - INTERVAL 1 DAY, c.t) DIV 30), 0)
     WHERE c.genre = 1;

    -- (2) vélos en atelier : intervention ouverte et signalement pris en charge
    IF v_nop > 0 THEN
        UPDATE seed_chunk SET t = GREATEST(fin + INTERVAL 10 MINUTE, v_h1 - INTERVAL m1 MINUTE) WHERE genre = 2;
        INSERT INTO intervention (id_velo, id_operateur, date_retrait, date_debut_reparation,
                                  date_remise_circulation, description_travaux)
        SELECT c.id_velo, o.id_utilisateur, c.t,
               IF(c.rr MOD 2 = 0, c.t + INTERVAL (30 + c.m1 MOD 270) MINUTE, NULL), NULL,
               ELT(1 + FLOOR(RAND() * 8), 'Remplacement de la chambre à air', 'Réglage des freins',
                   'Remplacement de la chaîne', 'Changement de la selle', 'Remplacement du pneu',
                   'Réparation du dérailleur', 'Remplacement de la batterie', 'Réglage de l''éclairage')
          FROM seed_chunk c
          JOIN seed_op o ON o.rn = 1 + (c.rr MOD v_nop)
         WHERE c.genre = 2;
        INSERT INTO signalement (id_utilisateur, id_velo, id_station, id_intervention, date_heure, description, statut)
        SELECT su.id_utilisateur, c.id_velo, NULL, i.id_intervention, c.t - INTERVAL 9 MINUTE,
               ELT(1 + FLOOR(RAND() * 8), 'Freins qui frottent', 'Pneu crevé', 'Chaîne qui saute', 'Selle cassée',
                   'Assistance électrique en panne', 'Éclairage défaillant', 'Garde-boue cassé', 'Pédale cassée'),
               'pris_en_charge'
          FROM seed_chunk c
          JOIN seed_usager su ON su.rn = c.ru
          JOIN intervention i ON i.id_velo = c.id_velo AND i.date_retrait = c.t
         WHERE c.genre = 2;
    END IF;

    -- (3) vélos défectueux : signalement ouvert, le vélo reste sur sa borne
    UPDATE seed_chunk SET t = GREATEST(fin + INTERVAL 1 MINUTE, v_h1 - INTERVAL m1 MINUTE) WHERE genre = 3;
    INSERT INTO signalement (id_utilisateur, id_velo, id_station, id_intervention, date_heure, description, statut)
    SELECT su.id_utilisateur, c.id_velo, NULL, NULL, c.t,
           ELT(1 + FLOOR(RAND() * 8), 'Freins qui frottent', 'Pneu crevé', 'Chaîne qui saute', 'Selle cassée',
               'Assistance électrique en panne', 'Éclairage défaillant', 'Garde-boue cassé', 'Pédale cassée'),
           'ouvert'
      FROM seed_chunk c
      JOIN seed_usager su ON su.rn = c.ru
     WHERE c.genre = 3;

    -- états et positions
    UPDATE velo SET id_borne = NULL, etat_velo = 'disponible';
    UPDATE velo v JOIN seed_chunk c ON c.id_velo = v.id_velo
       SET v.etat_velo = CASE c.genre WHEN 1 THEN 'en_location' WHEN 2 THEN 'en_atelier' ELSE 'defectueux' END;
    UPDATE velo v
      JOIN seed_velo s ON s.id_velo = v.id_velo
       SET v.id_borne = s.borne_final
     WHERE v.etat_velo IN ('disponible', 'defectueux');

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

DELIMITER ;
DELIMITER $$

-- =============================================================================
--  8. Facturation des trajets
--     sp_seed_facturation()
--     Une facture par abonnement et par mois écoulé, regroupant les trajets payants
--     du mois (émise le 1er du mois suivant, à 2 h). Les trajets du mois en cours
--     restent à facturer (id_facture NULL), comme avec sp_facturer_locations.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_facturation$$
CREATE PROCEDURE sp_seed_facturation()
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_m  DATETIME;
    DECLARE v_n  DATETIME;
    DECLARE v_cur DATETIME;
    DECLARE v_emit DATETIME;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF EXISTS (SELECT 1 FROM location WHERE id_facture IS NOT NULL LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Les trajets sont déjà facturés';
    END IF;
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    SET v_m   = TIMESTAMP(DATE_FORMAT(v_h0, '%Y-%m-01'));
    SET v_cur = TIMESTAMP(DATE_FORMAT(v_h1, '%Y-%m-01'));
    WHILE v_m < v_cur DO
        SET v_n    = v_m + INTERVAL 1 MONTH;
        SET v_emit = LEAST(v_n + INTERVAL 2 HOUR, v_h1);
        INSERT INTO facture (id_abonnement, date_emission, montant_total, statut_paiement)
        SELECT id_abonnement, v_emit, SUM(cout),
               IF(v_emit > v_h1 - INTERVAL 10 DAY, 'en_attente',
                  IF(RAND() < 0.97, 'payee', IF(RAND() < 0.6, 'echouee', 'remboursee')))
          FROM location
         WHERE date_heure_emprunt >= v_m AND date_heure_emprunt < v_n
           AND date_heure_restitution IS NOT NULL AND cout > 0
         GROUP BY id_abonnement;
        UPDATE location l
          JOIN facture f ON f.id_abonnement = l.id_abonnement AND f.date_emission = v_emit
           SET l.id_facture = f.id_facture
         WHERE l.date_heure_emprunt >= v_m AND l.date_heure_emprunt < v_n
           AND l.date_heure_restitution IS NOT NULL AND l.cout > 0;
        SET v_m = v_n;
    END WHILE;

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  9. Historiques (états et positions des vélos)
--     sp_seed_historique()
--     Reconstitue ce que les triggers auraient écrit si les données avaient été
--     créées au fil de l'eau, à partir des locations, signalements et
--     interventions. À lancer après sp_seed_etat_courant.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_historique$$
CREATE PROCEDURE sp_seed_historique()
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_nv INT UNSIGNED;
    DECLARE v_nl BIGINT UNSIGNED;
    DECLARE v_taille INT UNSIGNED;
    DECLARE v_lo INT UNSIGNED DEFAULT 1;
    DECLARE v_hi INT UNSIGNED;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF EXISTS (SELECT 1 FROM historique_etat LIMIT 1) OR EXISTS (SELECT 1 FROM historique_position LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Les historiques existent déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SELECT COUNT(*) INTO v_nv FROM seed_velo;
    SELECT COUNT(*) INTO v_nl FROM location;
    IF v_nv = 0 OR v_nl = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Appeler sp_seed_locations d''abord';
    END IF;
    SELECT h0 INTO v_h0 FROM seed_param WHERE id = 1;
    SET v_taille = GREATEST(1, FLOOR(300000 / GREATEST(1, v_nl / v_nv)));
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    -- ---- historique des états
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, v_h0, 'disponible' FROM velo;
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, date_heure_emprunt, 'en_location' FROM location;
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, date_heure_restitution, 'disponible' FROM location WHERE date_heure_restitution IS NOT NULL;
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, date_heure, 'defectueux' FROM signalement WHERE id_velo IS NOT NULL;
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, date_retrait, 'en_atelier' FROM intervention;
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    SELECT id_velo, date_remise_circulation, 'disponible' FROM intervention WHERE date_remise_circulation IS NOT NULL;

    -- ---- historique des positions, par paquets de vélos
    DROP TABLE IF EXISTS seed_chunk;
    CREATE TABLE seed_chunk (
        id_velo  INT UNSIGNED NOT NULL,
        dep      INT UNSIGNED NOT NULL,
        arr      INT UNSIGNED NULL,
        emp      DATETIME NOT NULL,
        resti    DATETIME NULL,
        prec     DATETIME NOT NULL,       -- fin du trajet précédent (ou début de l'historique)
        dernier  TINYINT NOT NULL,
        PRIMARY KEY (id_velo, emp)
    ) ENGINE=InnoDB;

    WHILE v_lo <= v_nv DO
        SET v_hi = LEAST(v_nv, v_lo + v_taille - 1);
        TRUNCATE TABLE seed_chunk;
        INSERT INTO seed_chunk (id_velo, dep, arr, emp, resti, prec, dernier)
        SELECT id_velo, id_borne_depart, id_borne_arrivee, date_heure_emprunt, date_heure_restitution,
               COALESCE(LAG(date_heure_restitution) OVER (PARTITION BY id_velo ORDER BY date_heure_emprunt), v_h0),
               ROW_NUMBER() OVER (PARTITION BY id_velo ORDER BY date_heure_emprunt DESC) = 1
          FROM location
         WHERE id_velo IN (SELECT id_velo FROM seed_velo WHERE rn BETWEEN v_lo AND v_hi);

        INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
        SELECT id_velo, dep, prec, emp, 'borne' FROM seed_chunk;
        INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
        SELECT id_velo, NULL, emp, resti, 'en_location' FROM seed_chunk;
        INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
        SELECT id_velo, arr, resti, NULL, 'borne' FROM seed_chunk WHERE dernier = 1 AND resti IS NOT NULL;
        -- vélos sans aucun trajet : posés sur leur borne depuis le début
        INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
        SELECT s.id_velo, s.borne_final, v_h0, NULL, 'borne'
          FROM seed_velo s
         WHERE s.rn BETWEEN v_lo AND v_hi AND s.last_end IS NULL
           AND NOT EXISTS (SELECT 1 FROM location l WHERE l.id_velo = s.id_velo);
        SET v_lo = v_hi + 1;
    END WHILE;

    -- ---- passages en atelier : la période sur borne est coupée en deux
    INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
    SELECT r.id_velo, r.id_borne, i.date_remise_circulation, r.date_heure_fin, 'borne'
      FROM intervention i
      JOIN historique_position r
        ON r.id_velo = i.id_velo AND r.type_position = 'borne'
       AND r.date_heure_debut <= i.date_retrait
       AND (r.date_heure_fin IS NULL OR r.date_heure_fin >= i.date_retrait)
     WHERE i.date_remise_circulation IS NOT NULL;
    UPDATE historique_position r
      JOIN intervention i
        ON r.id_velo = i.id_velo AND r.type_position = 'borne'
       AND r.date_heure_debut <= i.date_retrait
       AND (r.date_heure_fin IS NULL OR r.date_heure_fin >= i.date_retrait)
       SET r.date_heure_fin = i.date_retrait;
    INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, date_heure_fin, type_position)
    SELECT id_velo, NULL, date_retrait, date_remise_circulation, 'en_atelier' FROM intervention;

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

DELIMITER ;
DELIMITER $$

-- =============================================================================
--  10. Régulation : véhicules, tournées de rééquilibrage et déplacements de vélos
--      sp_seed_regulation(p_nb_tournees)
--      Les tournées ont lieu le matin (6 h à 14 h) et durent 1 h 30 à 5 h ;
--      chaque tournée déplace de 3 vélos à la capacité du véhicule. Les
--      déplacements ne sont pas reportés dans historique_position (données de
--      démonstration pour les écrans de régulation et les statistiques).
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_regulation$$
CREATE PROCEDURE sp_seed_regulation(
    IN p_nb_tournees INT UNSIGNED
)
BEGIN
    DECLARE v_h0 DATETIME;
    DECLARE v_h1 DATETIME;
    DECLARE v_nj INT;
    DECLARE v_nst INT UNSIGNED;
    DECLARE v_nv  INT UNSIGNED;
    DECLARE v_nreg INT UNSIGNED;
    DECLARE v_nveh INT UNSIGNED;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF EXISTS (SELECT 1 FROM tournee LIMIT 1) OR EXISTS (SELECT 1 FROM vehicule LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La régulation existe déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SELECT COUNT(*) INTO v_nst FROM station;
    SELECT COUNT(*) INTO v_nv  FROM seed_velo;
    SELECT COUNT(*) INTO v_nreg FROM operateur WHERE specialite = 'regulation';
    IF v_nst < 2 OR v_nv = 0 OR v_nreg = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Il faut au moins 2 stations, des vélos et un opérateur de régulation';
    END IF;
    SELECT h0, h1 INTO v_h0, v_h1 FROM seed_param WHERE id = 1;
    SET v_nj = TIMESTAMPDIFF(DAY, v_h0, v_h1) - 1;
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    -- véhicules : un pour 10 stations (au moins 2), capacité de 12 à 24 vélos
    SET v_nveh = GREATEST(2, CEIL(v_nst / 10));
    INSERT INTO vehicule (immatriculation, capacite_velos)
    SELECT CONCAT(CHAR(65 + (n MOD 26)), CHAR(65 + ((n DIV 26) MOD 26)), '-', LPAD(n MOD 1000, 3, '0'), '-',
                  CHAR(65 + ((n DIV 676) MOD 26)), CHAR(65 + ((n DIV 17576) MOD 26))),
           12 + (n MOD 4) * 4
      FROM seed_nums WHERE n <= v_nveh;

    -- opérateurs de régulation et véhicules numérotés
    DROP TABLE IF EXISTS seed_op;
    CREATE TABLE seed_op (rn INT UNSIGNED NOT NULL, id_utilisateur INT UNSIGNED NOT NULL, PRIMARY KEY (rn)) ENGINE=InnoDB;
    INSERT INTO seed_op (rn, id_utilisateur)
    SELECT ROW_NUMBER() OVER (ORDER BY id_utilisateur), id_utilisateur FROM operateur WHERE specialite = 'regulation';

    DROP TABLE IF EXISTS seed_chunk;
    CREATE TABLE seed_chunk (
        n INT UNSIGNED NOT NULL, rop INT UNSIGNED NOT NULL, rveh INT UNSIGNED NOT NULL,
        debut DATETIME NOT NULL, duree INT NOT NULL, nb_lignes INT NOT NULL DEFAULT 0,
        PRIMARY KEY (n)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk (n, rop, rveh, debut, duree)
    SELECT n.n, 1 + FLOOR(RAND() * v_nreg), 1 + FLOOR(RAND() * v_nveh),
           v_h0 + INTERVAL FLOOR(RAND() * v_nj) DAY + INTERVAL (360 + FLOOR(RAND() * 480)) MINUTE,
           90 + FLOOR(RAND() * 210)
      FROM seed_nums n WHERE n.n <= p_nb_tournees;
    UPDATE seed_chunk c
      JOIN (SELECT ROW_NUMBER() OVER (ORDER BY id_vehicule) AS rn, capacite_velos FROM vehicule) v ON v.rn = c.rveh
       SET c.nb_lignes = 3 + FLOOR(RAND() * (v.capacite_velos - 2));

    -- les identifiants sont attribués dans l'ordre de n : n = rang dans la table
    INSERT INTO tournee (id_operateur, id_vehicule, date_heure_debut, date_heure_fin)
    SELECT o.id_utilisateur, v.id_vehicule, c.debut, c.debut + INTERVAL c.duree MINUTE
      FROM seed_chunk c
      JOIN seed_op o ON o.rn = c.rop
      JOIN (SELECT ROW_NUMBER() OVER (ORDER BY id_vehicule) AS rn, id_vehicule FROM vehicule) v ON v.rn = c.rveh
     ORDER BY c.n;

    DROP TABLE IF EXISTS seed_chunk2;
    CREATE TABLE seed_chunk2 (
        n INT UNSIGNED NOT NULL, k INT UNSIGNED NOT NULL,
        rv INT UNSIGNED NOT NULL, rs INT UNSIGNED NOT NULL, ro INT UNSIGNED NOT NULL, mn INT NOT NULL,
        PRIMARY KEY (n, k)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk2 (n, k, rv, rs, ro, mn)
    SELECT c.n, k.n, 1 + FLOOR(RAND() * v_nv), 1 + FLOOR(RAND() * v_nst),
           FLOOR(RAND() * (v_nst - 1)), FLOOR(RAND() * 6)
      FROM seed_chunk c
      JOIN seed_nums k ON k.n <= c.nb_lignes;

    INSERT INTO ligne_tournee (id_tournee, num_ligne, id_velo, id_station_depart, id_station_arrivee, date_heure_deplacement)
    SELECT t.id_tournee, x.k, sv.id_velo, sd.id_station, sa.id_station,
           c.debut + INTERVAL LEAST(c.duree, 5 + x.k * 8 + x.mn) MINUTE
      FROM seed_chunk2 x
      JOIN seed_chunk c ON c.n = x.n
      JOIN (SELECT id_tournee, ROW_NUMBER() OVER (ORDER BY id_tournee) AS rn FROM tournee) t ON t.rn = x.n
      JOIN seed_velo sv ON sv.rn = x.rv
      JOIN (SELECT id_station, ROW_NUMBER() OVER (ORDER BY id_station) AS rn FROM station) sd ON sd.rn = x.rs
      JOIN (SELECT id_station, ROW_NUMBER() OVER (ORDER BY id_station) AS rn FROM station) sa
        ON sa.rn = 1 + ((x.rs + x.ro) MOD v_nst);

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  11. Relevés des stations (taux de remplissage par tranche horaire)
--      sp_seed_releves(p_jours, p_pas_min)
--      Un relevé par station tous les p_pas_min minutes sur les p_jours derniers
--      jours. Profil synthétique : les stations centrales se remplissent le matin
--      et se vident le soir, les stations périphériques font l'inverse ; bruit
--      déterministe par station et par instant ; 30 % de vélos électriques.
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_releves$$
CREATE PROCEDURE sp_seed_releves(
    IN p_jours   SMALLINT UNSIGNED,
    IN p_pas_min SMALLINT UNSIGNED
)
BEGIN
    DECLARE v_h1 DATETIME;
    DECLARE v_debut DATETIME;
    DECLARE v_pas INT UNSIGNED;
    DECLARE v_etapes INT UNSIGNED;
    DECLARE v_nst INT UNSIGNED;
    DECLARE v_bloc INT UNSIGNED;
    DECLARE v_lo INT UNSIGNED DEFAULT 1;
    DECLARE v_fk   INT DEFAULT @@session.foreign_key_checks;
    DECLARE v_uq   INT DEFAULT @@session.unique_checks;
    DECLARE v_mode INT DEFAULT COALESCE(@seed_mode, 0);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        SET @seed_mode = v_mode;
        SET foreign_key_checks = v_fk;
        SET unique_checks = v_uq;
        RESIGNAL;
    END;

    CALL sp_seed_preparer();
    IF p_jours < 1 OR p_pas_min < 1 OR p_jours * 1440 DIV p_pas_min > 1000000 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Paramètres invalides (au plus 1 000 000 relevés par station)';
    END IF;
    IF EXISTS (SELECT 1 FROM releve_station LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Des relevés existent déjà : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SELECT h1 INTO v_h1 FROM seed_param WHERE id = 1;
    SET v_debut  = TIMESTAMP(DATE(v_h1)) - INTERVAL p_jours DAY;
    SET v_etapes = p_jours * 1440 DIV p_pas_min;
    SET v_pas    = p_pas_min;
    SELECT COUNT(*) INTO v_nst FROM seed_station;
    SET v_bloc = GREATEST(1, FLOOR(500000 / v_etapes));
    SET @seed_mode = 1;
    SET foreign_key_checks = 0;
    SET unique_checks = 0;

    -- stations : capacité (bornes fonctionnelles) et caractère central (moitié la plus proche du centre)
    DROP TABLE IF EXISTS seed_chunk;
    CREATE TABLE seed_chunk (
        rn INT UNSIGNED NOT NULL, id_station INT UNSIGNED NOT NULL,
        cap SMALLINT UNSIGNED NOT NULL, central TINYINT NOT NULL,
        PRIMARY KEY (rn)
    ) ENGINE=InnoDB;
    INSERT INTO seed_chunk (rn, id_station, cap, central)
    SELECT ROW_NUMBER() OVER (ORDER BY st.id_station), st.id_station, COUNT(*),
           MIN(st.distance) <= (SELECT AVG(distance) FROM seed_station)
      FROM seed_station st
      JOIN seed_borne b ON b.id_station = st.id_station
     GROUP BY st.id_station;

    WHILE v_lo <= v_nst DO
        INSERT INTO releve_station (id_station, horodatage, nb_velos_mecaniques, nb_velos_electriques, nb_bornes_libres)
        SELECT y.id_station, y.t,
               y.nb - ROUND(y.nb * 0.3), ROUND(y.nb * 0.3), y.cap - y.nb
          FROM (SELECT x.id_station, x.t, x.cap,
                       ROUND(x.cap * LEAST(0.98, GREATEST(0.02, x.fill))) AS nb
                  FROM (SELECT c.id_station, c.cap,
                               v_debut + INTERVAL (n.n - 1) * v_pas MINUTE AS t,
                               0.5 + IF(c.central = 1, 1, -1) * 0.35 *
                                     SIN(6.283185307 * (HOUR(v_debut + INTERVAL (n.n - 1) * v_pas MINUTE)
                                                        + MINUTE(v_debut + INTERVAL (n.n - 1) * v_pas MINUTE) / 60 - 4) / 24)
                                   * IF(WEEKDAY(v_debut + INTERVAL (n.n - 1) * v_pas MINUTE) >= 5, 0.5, 1)
                                 + ((CRC32(CONCAT(c.id_station, '|', n.n)) MOD 1000) / 1000 - 0.5) * 0.2 AS fill
                          FROM seed_chunk c
                          JOIN seed_nums n ON n.n <= v_etapes
                         WHERE c.rn BETWEEN v_lo AND v_lo + v_bloc - 1) x) y;
        SET v_lo = v_lo + v_bloc;
    END WHILE;

    SET foreign_key_checks = v_fk;
    SET unique_checks = v_uq;
    SET @seed_mode = v_mode;
END$$

-- =============================================================================
--  12. Finalisation, contrôles et comptages
-- =============================================================================

-- Met à jour les statistiques de l'optimiseur et supprime les tables seed_*
DROP PROCEDURE IF EXISTS sp_seed_finaliser$$
CREATE PROCEDURE sp_seed_finaliser()
BEGIN
    ANALYZE NO_WRITE_TO_BINLOG TABLE utilisateur, usager, operateur, administrateur, station, borne,
        releve_station, velo, historique_etat, historique_position, formule, tranche_tarifaire,
        abonnement, facture, location, intervention, signalement, vehicule, tournee, ligne_tournee;
    CALL sp_seed_nettoyer();
END$$

-- Nombre de lignes de chaque table (comptage exact)
DROP PROCEDURE IF EXISTS sp_seed_compter$$
CREATE PROCEDURE sp_seed_compter()
BEGIN
    SELECT 'utilisateur' AS table_name, COUNT(*) AS nb_lignes FROM utilisateur
    UNION ALL SELECT 'usager', COUNT(*) FROM usager
    UNION ALL SELECT 'operateur', COUNT(*) FROM operateur
    UNION ALL SELECT 'administrateur', COUNT(*) FROM administrateur
    UNION ALL SELECT 'station', COUNT(*) FROM station
    UNION ALL SELECT 'borne', COUNT(*) FROM borne
    UNION ALL SELECT 'releve_station', COUNT(*) FROM releve_station
    UNION ALL SELECT 'velo', COUNT(*) FROM velo
    UNION ALL SELECT 'historique_etat', COUNT(*) FROM historique_etat
    UNION ALL SELECT 'historique_position', COUNT(*) FROM historique_position
    UNION ALL SELECT 'formule', COUNT(*) FROM formule
    UNION ALL SELECT 'tranche_tarifaire', COUNT(*) FROM tranche_tarifaire
    UNION ALL SELECT 'abonnement', COUNT(*) FROM abonnement
    UNION ALL SELECT 'facture', COUNT(*) FROM facture
    UNION ALL SELECT 'location', COUNT(*) FROM location
    UNION ALL SELECT 'intervention', COUNT(*) FROM intervention
    UNION ALL SELECT 'signalement', COUNT(*) FROM signalement
    UNION ALL SELECT 'vehicule', COUNT(*) FROM vehicule
    UNION ALL SELECT 'tournee', COUNT(*) FROM tournee
    UNION ALL SELECT 'ligne_tournee', COUNT(*) FROM ligne_tournee;
END$$

-- Contrôles de cohérence : une ligne par contrôle, 0 anomalie attendu
-- (les chevauchements d'un même usager sont signalés à titre indicatif : les
--  trajets sont tirés au hasard par usager)
DROP PROCEDURE IF EXISTS sp_seed_verifier$$
CREATE PROCEDURE sp_seed_verifier()
BEGIN
    DROP TEMPORARY TABLE IF EXISTS tmp_verif;
    CREATE TEMPORARY TABLE tmp_verif (
        ordre INT AUTO_INCREMENT PRIMARY KEY,
        controle VARCHAR(90) NOT NULL,
        anomalies BIGINT NOT NULL,
        indicatif BOOLEAN NOT NULL DEFAULT FALSE
    );
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : abonnement orphelin', COUNT(*) FROM location l LEFT JOIN abonnement a USING (id_abonnement) WHERE a.id_abonnement IS NULL;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : vélo ou borne orphelins', COUNT(*) FROM location l
      LEFT JOIN velo v ON v.id_velo = l.id_velo
      LEFT JOIN borne b1 ON b1.id_borne = l.id_borne_depart
      LEFT JOIN borne b2 ON b2.id_borne = l.id_borne_arrivee
     WHERE v.id_velo IS NULL OR b1.id_borne IS NULL OR (l.id_borne_arrivee IS NOT NULL AND b2.id_borne IS NULL);
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : facture orpheline', COUNT(*) FROM location l LEFT JOIN facture f USING (id_facture)
     WHERE l.id_facture IS NOT NULL AND f.id_facture IS NULL;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'abonnements / factures / historiques : orphelins', 
           (SELECT COUNT(*) FROM abonnement a LEFT JOIN usager u ON u.id_utilisateur = a.id_utilisateur WHERE u.id_utilisateur IS NULL)
         + (SELECT COUNT(*) FROM facture f LEFT JOIN abonnement a USING (id_abonnement) WHERE a.id_abonnement IS NULL)
         + (SELECT COUNT(*) FROM historique_etat h LEFT JOIN velo v USING (id_velo) WHERE v.id_velo IS NULL)
         + (SELECT COUNT(*) FROM historique_position h LEFT JOIN velo v USING (id_velo) WHERE v.id_velo IS NULL);
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'maintenance et régulation : orphelins',
           (SELECT COUNT(*) FROM intervention i LEFT JOIN operateur o ON o.id_utilisateur = i.id_operateur WHERE o.id_utilisateur IS NULL)
         + (SELECT COUNT(*) FROM signalement s LEFT JOIN utilisateur u USING (id_utilisateur) WHERE u.id_utilisateur IS NULL)
         + (SELECT COUNT(*) FROM tournee t LEFT JOIN operateur o ON o.id_utilisateur = t.id_operateur WHERE o.id_utilisateur IS NULL)
         + (SELECT COUNT(*) FROM ligne_tournee l LEFT JOIN tournee t USING (id_tournee) WHERE t.id_tournee IS NULL);
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : emprunt hors période de validité de l''abonnement', COUNT(*)
      FROM location l JOIN abonnement a USING (id_abonnement)
     WHERE l.date_heure_emprunt < a.date_debut OR l.date_heure_emprunt >= a.date_fin;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : chevauchement ou rupture de chaîne pour un même vélo', COUNT(*)
      FROM (SELECT id_borne_depart AS dep, date_heure_emprunt AS e,
                   LAG(id_borne_arrivee)        OVER w AS pa,
                   LAG(date_heure_restitution)  OVER w AS pf
              FROM location
            WINDOW w AS (PARTITION BY id_velo ORDER BY date_heure_emprunt)) x
     WHERE (pa IS NOT NULL AND pa <> dep) OR (pf IS NOT NULL AND pf > e);
    INSERT INTO tmp_verif (controle, anomalies, indicatif)
    SELECT 'locations : chevauchement pour un même abonnement (indicatif)', COUNT(*), TRUE
      FROM (SELECT date_heure_emprunt AS e, LAG(date_heure_restitution) OVER w AS pf
              FROM location
            WINDOW w AS (PARTITION BY id_abonnement ORDER BY date_heure_emprunt)) x
     WHERE pf IS NOT NULL AND pf > e;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations en cours <> vélos en_location',
           ABS((SELECT COUNT(*) FROM location WHERE date_heure_restitution IS NULL)
             - (SELECT COUNT(*) FROM velo WHERE etat_velo = 'en_location'));
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'locations : coût différent de fn_calculer_cout (échantillon)', COUNT(*)
      FROM location l
     WHERE l.id_location MOD 997 = 0 AND l.date_heure_restitution IS NOT NULL
       AND fn_calculer_cout(l.id_abonnement, l.id_velo, l.duree_min) <> l.cout;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'factures de trajets : montant <> somme des coûts', COUNT(*)
      FROM (SELECT f.id_facture FROM facture f JOIN location l ON l.id_facture = f.id_facture
             GROUP BY f.id_facture, f.montant_total HAVING SUM(l.cout) <> f.montant_total) x;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'vélos : dernier état de l''historique <> état courant', COUNT(*)
      FROM velo v
      JOIN (SELECT id_velo, etat_velo,
                   ROW_NUMBER() OVER (PARTITION BY id_velo ORDER BY date_heure DESC, id_hist_etat DESC) AS r
              FROM historique_etat) h ON h.id_velo = v.id_velo AND h.r = 1
     WHERE h.etat_velo <> v.etat_velo;
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'vélos : position courante <> historique de position', COUNT(*)
      FROM velo v
      LEFT JOIN historique_position h ON h.id_velo = v.id_velo AND h.date_heure_fin IS NULL
     WHERE h.id_hist_pos IS NULL
        OR (v.id_borne IS NULL AND h.type_position = 'borne')
        OR (v.id_borne IS NOT NULL AND (h.id_borne IS NULL OR h.id_borne <> v.id_borne));
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'vélos : état incompatible avec la position', COUNT(*)
      FROM velo WHERE (etat_velo IN ('en_location', 'en_atelier') AND id_borne IS NOT NULL)
                   OR (etat_velo IN ('disponible', 'defectueux') AND id_borne IS NULL);
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'vélos défectueux ou en atelier sans signalement ouvert', COUNT(*)
      FROM velo v
     WHERE v.etat_velo IN ('defectueux', 'en_atelier')
       AND NOT EXISTS (SELECT 1 FROM signalement s WHERE s.id_velo = v.id_velo AND s.statut <> 'clos');
    INSERT INTO tmp_verif (controle, anomalies)
    SELECT 'abonnements : chevauchement pour un même usager (hors tickets journée)', COUNT(*)
      FROM (SELECT a.date_debut AS d, LAG(a.date_fin) OVER (PARTITION BY a.id_utilisateur ORDER BY a.date_debut) AS pf
              FROM abonnement a JOIN formule f USING (id_formule)
             WHERE f.libelle <> 'Ticket journée') x
     WHERE pf IS NOT NULL AND pf > d;

    SELECT controle, anomalies,
           IF(anomalies = 0, 'OK', IF(indicatif, 'INDICATIF', 'ANOMALIE')) AS statut
      FROM tmp_verif ORDER BY ordre;
    DROP TEMPORARY TABLE tmp_verif;
END$$

-- =============================================================================
--  13. Orchestrateurs
--      sp_seed_tout(stations, vélos, usagers, locations, jours de relevés)
--      Base vide requise (sp_seed_vider('OUI') pour repartir de zéro).
--      Presets : sp_seed_petit (tests), sp_seed_demo (≈ 1 M de locations),
--                sp_seed_gros (≈ 5 M de locations).
-- =============================================================================
DROP PROCEDURE IF EXISTS sp_seed_tout$$
CREATE PROCEDURE sp_seed_tout(
    IN p_nb_stations  SMALLINT UNSIGNED,
    IN p_nb_velos     INT UNSIGNED,
    IN p_nb_usagers   INT UNSIGNED,
    IN p_nb_locations BIGINT UNSIGNED,
    IN p_jours_releves SMALLINT UNSIGNED
)
BEGIN
    DECLARE v_moy INT;
    DECLARE v_min INT;
    DECLARE v_nb_op INT;

    IF EXISTS (SELECT 1 FROM station LIMIT 1) OR EXISTS (SELECT 1 FROM utilisateur LIMIT 1) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'La base n''est pas vide : appeler sp_seed_vider(''OUI'') d''abord';
    END IF;
    SET v_moy = CEIL(p_nb_velos * 1.3 / p_nb_stations);
    SET v_min = GREATEST(6, v_moy - 6);
    SET v_nb_op = GREATEST(6, LEAST(5000, p_nb_stations DIV 2 + p_nb_velos DIV 100));

    SELECT NOW() AS heure, 'préparation et référentiels' AS etape;
    CALL sp_seed_preparer();
    CALL sp_seed_reference();
    SELECT NOW() AS heure, 'stations et bornes' AS etape;
    CALL sp_seed_stations(p_nb_stations, v_min, v_min + 12);
    SELECT NOW() AS heure, 'flotte' AS etape;
    CALL sp_seed_flotte(p_nb_velos, 0.30);
    SELECT NOW() AS heure, 'utilisateurs' AS etape;
    CALL sp_seed_utilisateurs(p_nb_usagers, v_nb_op);
    SELECT NOW() AS heure, 'abonnements' AS etape;
    CALL sp_seed_abonnements();
    SELECT NOW() AS heure, 'locations' AS etape;
    CALL sp_seed_locations(p_nb_locations);
    SELECT NOW() AS heure, 'maintenance' AS etape;
    CALL sp_seed_maintenance(GREATEST(10, p_nb_locations DIV 400));
    SELECT NOW() AS heure, 'état courant' AS etape;
    CALL sp_seed_etat_courant();
    SELECT NOW() AS heure, 'facturation' AS etape;
    CALL sp_seed_facturation();
    SELECT NOW() AS heure, 'historiques' AS etape;
    CALL sp_seed_historique();
    SELECT NOW() AS heure, 'régulation' AS etape;
    CALL sp_seed_regulation(GREATEST(20, p_nb_locations DIV 2000));
    SELECT NOW() AS heure, 'relevés des stations' AS etape;
    CALL sp_seed_releves(p_jours_releves, 15);
    SELECT NOW() AS heure, 'contrôles' AS etape;
    CALL sp_seed_verifier();
    CALL sp_seed_compter();
    CALL sp_seed_finaliser();
    SELECT NOW() AS heure, 'terminé' AS etape;
END$$

DROP PROCEDURE IF EXISTS sp_seed_petit$$
CREATE PROCEDURE sp_seed_petit()
BEGIN
    CALL sp_seed_tout(20, 300, 2000, 50000, 30);
END$$

DROP PROCEDURE IF EXISTS sp_seed_demo$$
CREATE PROCEDURE sp_seed_demo()
BEGIN
    CALL sp_seed_tout(100, 2000, 100000, 1000000, 90);
END$$

DROP PROCEDURE IF EXISTS sp_seed_gros$$
CREATE PROCEDURE sp_seed_gros()
BEGIN
    CALL sp_seed_tout(300, 6000, 500000, 5000000, 90);
END$$

DELIMITER ;
