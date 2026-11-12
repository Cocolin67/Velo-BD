-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  SIMULATION : activité continue du réseau par événements planifiés
--
--  À exécuter APRÈS schema.sql, triggers.sql, procedures.sql et seed.sql
--  (sur une base peuplée : il faut des stations, des vélos, des usagers abonnés,
--  des opérateurs et des véhicules) :
--      mysql -u <utilisateur> -p --default-character-set=utf8mb4 < simulation.sql
--
--  Script ré-exécutable. Nécessite l'ordonnanceur d'événements :
--      SET GLOBAL event_scheduler = ON;     (ou event_scheduler=ON dans my.ini)
--
--  Objectif : faire « vivre » la base. Les données de seed.sql s'arrêtent à la date
--  du chargement ; ces événements prolongent l'historique en temps réel, de sorte
--  que la carte, les tableaux de bord et les statistiques évoluent au fil du temps.
--
--  Principe : chaque événement appelle une procédure sp_sim_* qui joue le rôle des
--  usagers et des opérateurs en appelant les MÊMES procédures métier que
--  l'application (sp_emprunter_velo, sp_rendre_velo, sp_souscrire_abonnement,
--  sp_signaler_probleme, sp_ouvrir_intervention, sp_deplacer_velo_tournee...).
--  Les règles de gestion (abonnement valide, un vélo par usager, borne libre...),
--  les triggers (historisation, coût) et les événements existants (relevés,
--  expiration, facturation) s'appliquent donc normalement. Une action refusée par
--  une règle métier (vélo pris entre-temps, borne occupée...) est simplement
--  ignorée, comme le serait la tentative d'un vrai usager.
--
--    Événement            Fréquence     Activité simulée
--    ev_sim_trajets       1 minute      restitutions puis emprunts, selon l'heure
--                                       (pointes 8 h et 18 h, vers le centre le matin et
--                                       vers la périphérie le soir, creux la nuit, week-end
--                                       plus calme)
--    ev_sim_abonnements   1 heure       inscriptions de nouveaux usagers et
--                                       réabonnements d'usagers sans abonnement valide
--    ev_sim_signalements  15 minutes    signalements de vélos ou de stations
--    ev_sim_maintenance   15 minutes    retrait des vélos défectueux, réparation,
--                                       remise en circulation (7 h - 19 h)
--    ev_sim_regulation    1 heure       tournées de rééquilibrage pleine -> vide
--                                       (6 h - 22 h)
--
--  Pilotage :
--      CALL sp_sim_activer(FALSE);          -- suspend la simulation (ex. avant un banc
--                                           -- de mesure : bin/bench-stats.php)
--      CALL sp_sim_activer(TRUE);           -- la relance
--      CALL sp_sim_bilan(24);               -- activité simulée des 24 dernières heures
--  Les intensités se règlent dans les appels des événements (section 4).
--  Les procédures sp_sim_* peuvent aussi être appelées à la main pour tester.
--
--  Les usagers créés par la simulation ont une adresse en @sim.velo.local et un
--  hash de mot de passe factice (comptes non utilisables). Les comptes de
--  démonstration (@velo.local) ne sont jamais utilisés par la simulation.
--
--  Les tournées et les remises en circulation déplacent des vélos hors trajet : le
--  contrôle « rupture de chaîne pour un même vélo » de sp_seed_verifier, prévu pour
--  les seules données de seed.sql, les compte alors comme anomalies (attendues).
--
--  Pour tout supprimer : DROP EVENT des ev_sim_* et DROP PROCEDURE / FUNCTION des
--  objets *_sim_* (les données produites restent, elles sont cohérentes).
-- =============================================================================

USE velo_libre_service;

DELIMITER $$

-- =============================================================================
--  1. Fonctions utilitaires
-- =============================================================================

-- Arrondi aléatoire : 2,3 donne 2 avec une probabilité de 70 % et 3 avec 30 %.
-- Permet des intensités fractionnaires (0,2 inscription par heure, etc.).
DROP FUNCTION IF EXISTS fn_sim_arrondi$$
CREATE FUNCTION fn_sim_arrondi(p_valeur DOUBLE) RETURNS INT
NOT DETERMINISTIC NO SQL
BEGIN
    RETURN FLOOR(GREATEST(p_valeur, 0) + RAND());
END$$

-- Intensité de l'activité selon l'heure, en % de l'heure de pointe
-- (pointes à 8 h et 18 h). Le week-end, l'activité est réduite et plus étalée.
DROP FUNCTION IF EXISTS fn_sim_profil_horaire$$
CREATE FUNCTION fn_sim_profil_horaire(p_instant DATETIME) RETURNS DOUBLE
NOT DETERMINISTIC NO SQL
BEGIN
    DECLARE v_heure INT DEFAULT HOUR(p_instant);
    IF DAYOFWEEK(p_instant) IN (1, 7) THEN          -- dimanche, samedi
        RETURN ELT(v_heure + 1,  4,  3,  2,  1,  1,  1,  3,  8, 15, 25, 35, 45,
                                45, 45, 50, 55, 55, 50, 40, 30, 20, 12,  8,  5);
    END IF;
    RETURN ELT(v_heure + 1,  3,  2,  1,  1,  1,  3, 15, 55, 100, 60, 30, 30,
                            45, 40, 30, 30, 45, 85, 100, 60, 35, 20, 12,  6);
END$$

-- Sens des trajets selon l'heure (mouvement pendulaire) : 1 = vers le centre
-- (matin de semaine), -1 = vers la périphérie (soir de semaine), 0 = indifférent.
DROP FUNCTION IF EXISTS fn_sim_sens$$
CREATE FUNCTION fn_sim_sens(p_instant DATETIME) RETURNS INT
NOT DETERMINISTIC NO SQL
BEGIN
    IF DAYOFWEEK(p_instant) IN (1, 7) THEN
        RETURN 0;
    END IF;
    RETURN CASE WHEN HOUR(p_instant) BETWEEN 6 AND 10  THEN 1
                WHEN HOUR(p_instant) BETWEEN 16 AND 20 THEN -1
                ELSE 0 END;
END$$

-- Une borne libre, fonctionnelle, dans une station en service, tirée au hasard
-- (NULL si le réseau est plein). Le tirage part d'un identifiant aléatoire et lit
-- l'index de la clé primaire : pas de tri de toutes les bornes.
DROP FUNCTION IF EXISTS fn_sim_borne_tiree$$
CREATE FUNCTION fn_sim_borne_tiree() RETURNS INT UNSIGNED
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_pivot INT UNSIGNED;
    DECLARE v_borne INT UNSIGNED DEFAULT NULL;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    SELECT FLOOR(RAND() * MAX(id_borne)) INTO v_pivot FROM borne;

    SELECT b.id_borne INTO v_borne
      FROM borne b
      JOIN station s ON s.id_station = b.id_station
      LEFT JOIN velo v ON v.id_borne = b.id_borne
     WHERE b.id_borne >= v_pivot
       AND b.etat_borne = 'fonctionnelle' AND s.etat_station = 'en_service'
       AND v.id_velo IS NULL
     ORDER BY b.id_borne
     LIMIT 1;

    IF v_borne IS NULL THEN                         -- rien après le pivot : on repart du début
        SELECT b.id_borne INTO v_borne
          FROM borne b
          JOIN station s ON s.id_station = b.id_station
          LEFT JOIN velo v ON v.id_borne = b.id_borne
         WHERE b.etat_borne = 'fonctionnelle' AND s.etat_station = 'en_service'
           AND v.id_velo IS NULL
         ORDER BY b.id_borne
         LIMIT 1;
    END IF;
    RETURN v_borne;
END$$

-- Borne libre d'arrivée orientée : parmi trois bornes tirées au hasard, garde la
-- plus proche du centre du réseau (p_sens = 1) ou la plus éloignée (p_sens = -1).
-- Le matin, les stations centrales se remplissent et les stations périphériques se
-- vident, et inversement le soir : c'est ce déséquilibre que corrige la régulation.
DROP FUNCTION IF EXISTS fn_sim_borne_libre$$
CREATE FUNCTION fn_sim_borne_libre(p_sens INT) RETURNS INT UNSIGNED
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_lat       DOUBLE;
    DECLARE v_lon       DOUBLE;
    DECLARE v_borne     INT UNSIGNED;
    DECLARE v_candidate INT UNSIGNED;
    DECLARE v_dist      DOUBLE;
    DECLARE v_meilleure DOUBLE;
    DECLARE v_i         INT DEFAULT 0;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF COALESCE(p_sens, 0) = 0 THEN
        RETURN fn_sim_borne_tiree();
    END IF;

    SELECT AVG(latitude), AVG(longitude) INTO v_lat, v_lon FROM station;
    WHILE v_i < 3 DO
        SET v_i = v_i + 1;
        SET v_candidate = fn_sim_borne_tiree();
        IF v_candidate IS NOT NULL THEN
            -- distance au centre (carré, en degrés : suffit pour comparer)
            SELECT p_sens * (POW(s.latitude - v_lat, 2) + POW(s.longitude - v_lon, 2))
              INTO v_dist
              FROM borne b JOIN station s ON s.id_station = b.id_station
             WHERE b.id_borne = v_candidate;
            IF v_borne IS NULL OR v_dist < v_meilleure THEN
                SET v_borne = v_candidate, v_meilleure = v_dist;
            END IF;
        END IF;
    END WHILE;
    RETURN v_borne;
END$$

-- Un usager tiré au hasard (hors comptes de démonstration)
DROP FUNCTION IF EXISTS fn_sim_usager$$
CREATE FUNCTION fn_sim_usager() RETURNS INT UNSIGNED
NOT DETERMINISTIC READS SQL DATA
BEGIN
    DECLARE v_pivot  INT UNSIGNED;
    DECLARE v_usager INT UNSIGNED DEFAULT NULL;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    SELECT FLOOR(RAND() * MAX(id_utilisateur)) INTO v_pivot FROM usager;

    SELECT us.id_utilisateur INTO v_usager
      FROM usager us
      JOIN utilisateur u ON u.id_utilisateur = us.id_utilisateur
     WHERE us.id_utilisateur >= v_pivot AND u.email NOT LIKE '%@velo.local'
     ORDER BY us.id_utilisateur
     LIMIT 1;
    RETURN v_usager;
END$$

-- =============================================================================
--  2. Activité des usagers
-- =============================================================================

-- Trajets de la minute écoulée.
--   p_departs_pointe : emprunts par minute à l'heure de pointe ; NULL = 1 % de la
--                      flotte (3 pour 300 vélos, 60 pour 6 000) ;
--   p_duree_moyenne  : durée moyenne d'un trajet en minutes (chaque minute, un trajet
--                      en cours se termine avec une probabilité 1 / p_duree_moyenne) ;
--                      un trajet est toujours terminé au bout de 3 heures.
-- Les restitutions passent d'abord, pour libérer des bornes.
DROP PROCEDURE IF EXISTS sp_sim_trajets$$
CREATE PROCEDURE sp_sim_trajets(IN p_departs_pointe INT, IN p_duree_moyenne INT)
corps: BEGIN
    DECLARE v_usager   INT UNSIGNED;
    DECLARE v_velo     INT UNSIGNED;
    DECLARE v_borne    INT UNSIGNED;
    DECLARE v_pivot    INT UNSIGNED;
    DECLARE v_departs  INT;
    DECLARE v_i        INT DEFAULT 0;
    DECLARE v_location BIGINT UNSIGNED;
    DECLARE v_duree    INT UNSIGNED;
    DECLARE v_cout     DECIMAL(8, 2);
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    -- une seule exécution à la fois (si une minute déborde sur la suivante)
    IF GET_LOCK('velo_sim_trajets', 0) <> 1 THEN
        LEAVE corps;
    END IF;

    -- ---- Restitutions : trajets en cours qui se terminent cette minute ----------
    DROP TEMPORARY TABLE IF EXISTS sim_retour;
    CREATE TEMPORARY TABLE sim_retour (
        id_usager INT UNSIGNED NOT NULL PRIMARY KEY
    ) ENGINE=MEMORY;

    -- velo_en_cours IS NOT NULL : lecture de l'index unique des locations en cours
    INSERT IGNORE INTO sim_retour (id_usager)
    SELECT a.id_utilisateur
      FROM location l
      JOIN abonnement  a ON a.id_abonnement  = l.id_abonnement
      JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
     WHERE l.velo_en_cours IS NOT NULL
       AND u.email NOT LIKE '%@velo.local'
       AND (l.date_heure_emprunt <= NOW() - INTERVAL 3 HOUR
            OR (l.date_heure_emprunt <= NOW() - INTERVAL 2 MINUTE
                AND RAND() < 1 / GREATEST(COALESCE(p_duree_moyenne, 15), 3)));

    retours: LOOP
        SET v_usager = NULL;
        SELECT id_usager INTO v_usager FROM sim_retour LIMIT 1;
        IF v_usager IS NULL THEN
            LEAVE retours;
        END IF;
        DELETE FROM sim_retour WHERE id_usager = v_usager;

        SET v_borne = fn_sim_borne_libre(fn_sim_sens(NOW()));
        IF v_borne IS NULL THEN
            LEAVE retours;                          -- réseau plein : on réessaiera
        END IF;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_rendre_velo(v_usager, v_borne, v_location, v_duree, v_cout);
        END;
    END LOOP;
    DROP TEMPORARY TABLE sim_retour;

    -- ---- Emprunts ------------------------------------------------------------
    IF p_departs_pointe IS NULL THEN
        SELECT GREATEST(1, ROUND(COUNT(*) / 100)) INTO p_departs_pointe FROM velo;
    END IF;
    SET v_departs = fn_sim_arrondi(p_departs_pointe * fn_sim_profil_horaire(NOW()) / 100);

    WHILE v_i < v_departs DO
        SET v_i = v_i + 1;

        -- un usager abonné, sans vélo en cours (abo_en_cours : index unique)
        SET v_usager = NULL;
        SELECT FLOOR(RAND() * MAX(id_abonnement)) INTO v_pivot FROM abonnement;
        SELECT a.id_utilisateur INTO v_usager
          FROM abonnement a
          JOIN utilisateur u ON u.id_utilisateur = a.id_utilisateur
         WHERE a.id_abonnement >= v_pivot
           AND a.statut = 'actif' AND a.date_debut <= NOW() AND a.date_fin > NOW()
           AND u.email NOT LIKE '%@velo.local'
           AND NOT EXISTS (SELECT 1 FROM location l WHERE l.abo_en_cours = a.id_abonnement)
         ORDER BY a.id_abonnement
         LIMIT 1;

        -- un vélo disponible sur une borne en service
        SET v_velo = NULL;
        SELECT FLOOR(RAND() * MAX(id_velo)) INTO v_pivot FROM velo;
        SELECT v.id_velo INTO v_velo
          FROM velo v
          JOIN borne   b ON b.id_borne   = v.id_borne
          JOIN station s ON s.id_station = b.id_station
         WHERE v.id_velo >= v_pivot
           AND v.etat_velo = 'disponible'
           AND b.etat_borne = 'fonctionnelle' AND s.etat_station = 'en_service'
         ORDER BY v.id_velo
         LIMIT 1;

        IF v_usager IS NOT NULL AND v_velo IS NOT NULL THEN
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
                CALL sp_emprunter_velo(v_usager, v_velo, v_location);
            END;
        END IF;
    END WHILE;

    DO RELEASE_LOCK('velo_sim_trajets');
END$$

-- Inscriptions et réabonnements de l'heure écoulée (nombres moyens par jour,
-- répartis selon le profil horaire).
--   p_inscriptions_jour   : nouveaux usagers, qui souscrivent aussitôt ;
--   p_reabonnements_jour  : usagers existants sans abonnement valide qui en reprennent un.
-- Formules : ticket journée 40 %, mensuel 30 %, annuel 20 %, tarif réduit 10 %.
DROP PROCEDURE IF EXISTS sp_sim_abonnements$$
CREATE PROCEDURE sp_sim_abonnements(IN p_inscriptions_jour INT, IN p_reabonnements_jour INT)
BEGIN
    DECLARE v_part      DOUBLE;
    DECLARE v_nb        INT;
    DECLARE v_i         INT;
    DECLARE v_usager    INT UNSIGNED;
    DECLARE v_pivot     INT UNSIGNED;
    DECLARE v_formule   INT UNSIGNED;
    DECLARE v_libelle   VARCHAR(100);
    DECLARE v_tirage    DOUBLE;
    DECLARE v_prenom    VARCHAR(100);
    DECLARE v_nom       VARCHAR(100);
    DECLARE v_abonnement INT UNSIGNED;
    DECLARE v_facture   INT UNSIGNED;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    -- part de la journée que représente l'heure courante (somme des parts = 1)
    SET v_part = fn_sim_profil_horaire(NOW()) / 809;   -- 809 = somme du profil de semaine

    -- ---- Nouveaux usagers ----------------------------------------------------
    SET v_nb = fn_sim_arrondi(p_inscriptions_jour * v_part);
    SET v_i = 0;
    WHILE v_i < v_nb DO
        SET v_i = v_i + 1;
        SET v_prenom = ELT(1 + FLOOR(RAND() * 16),
            'Camille', 'Léa', 'Manon', 'Chloé', 'Inès', 'Jade', 'Louise', 'Emma',
            'Lucas', 'Hugo', 'Louis', 'Nathan', 'Gabriel', 'Jules', 'Arthur', 'Adam');
        SET v_nom = ELT(1 + FLOOR(RAND() * 16),
            'Martin', 'Bernard', 'Thomas', 'Petit', 'Robert', 'Richard', 'Durand', 'Dubois',
            'Moreau', 'Laurent', 'Simon', 'Michel', 'Lefebvre', 'Leroy', 'Roux', 'Fournier');
        SET v_usager = NULL;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_inscrire_usager(
                v_nom, v_prenom,
                LOWER(CONCAT(v_prenom, '.', v_nom, '.', DATE_FORMAT(NOW(6), '%y%m%d%H%i%s%f'),
                             v_i, '@sim.velo.local')),
                SHA2(UUID(), 256),                  -- hash factice : compte non utilisable
                CURDATE() - INTERVAL (6600 + FLOOR(RAND() * 18000)) DAY,
                CONCAT('06', LPAD(FLOOR(RAND() * 100000000), 8, '0')),
                v_usager);
        END;

        IF v_usager IS NOT NULL THEN
            SET v_tirage = RAND();
            SET v_libelle = CASE WHEN v_tirage < 0.4 THEN 'Ticket journée'
                                 WHEN v_tirage < 0.7 THEN 'Abonnement mensuel'
                                 WHEN v_tirage < 0.9 THEN 'Abonnement annuel'
                                 ELSE 'Tarif réduit' END;
            SET v_formule = NULL;
            SELECT id_formule INTO v_formule FROM formule WHERE libelle = v_libelle;
            IF v_formule IS NULL THEN               -- référentiel différent : formule au hasard
                SELECT id_formule INTO v_formule FROM formule ORDER BY RAND() LIMIT 1;
            END IF;
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
                CALL sp_souscrire_abonnement(v_usager, v_formule,
                                             v_libelle <> 'Ticket journée' AND RAND() < 0.5,
                                             v_abonnement, v_facture);
            END;
        END IF;
    END WHILE;

    -- ---- Réabonnements -------------------------------------------------------
    SET v_nb = fn_sim_arrondi(p_reabonnements_jour * v_part);
    SET v_i = 0;
    WHILE v_i < v_nb DO
        SET v_i = v_i + 1;

        -- un usager sans abonnement valide (index idx_abo_usager_statut_fin)
        SET v_usager = NULL;
        SELECT FLOOR(RAND() * MAX(id_utilisateur)) INTO v_pivot FROM usager;
        SELECT us.id_utilisateur INTO v_usager
          FROM usager us
          JOIN utilisateur u ON u.id_utilisateur = us.id_utilisateur
         WHERE us.id_utilisateur >= v_pivot
           AND u.email NOT LIKE '%@velo.local'
           AND NOT EXISTS (SELECT 1 FROM abonnement a
                            WHERE a.id_utilisateur = us.id_utilisateur
                              AND a.statut = 'actif' AND a.date_fin > NOW())
         ORDER BY us.id_utilisateur
         LIMIT 1;

        IF v_usager IS NOT NULL THEN
            -- il reprend le plus souvent sa dernière formule
            SET v_formule = NULL;
            SELECT id_formule INTO v_formule
              FROM abonnement WHERE id_utilisateur = v_usager
             ORDER BY date_debut DESC LIMIT 1;
            IF v_formule IS NULL OR RAND() < 0.2 THEN
                SELECT id_formule INTO v_formule FROM formule ORDER BY RAND() LIMIT 1;
            END IF;
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
                CALL sp_souscrire_abonnement(v_usager, v_formule, RAND() < 0.3,
                                             v_abonnement, v_facture);
            END;
        END IF;
    END WHILE;
END$$

-- Signalements du quart d'heure écoulé (nombre moyen par jour, selon le profil horaire).
-- 80 % visent un vélo disponible (il passe en « défectueux » par trg_signalement_ai),
-- 20 % une station.
DROP PROCEDURE IF EXISTS sp_sim_signalements$$
CREATE PROCEDURE sp_sim_signalements(IN p_par_jour INT)
BEGIN
    DECLARE v_nb     INT;
    DECLARE v_i      INT DEFAULT 0;
    DECLARE v_auteur INT UNSIGNED;
    DECLARE v_velo   INT UNSIGNED;
    DECLARE v_station INT UNSIGNED;
    DECLARE v_pivot  INT UNSIGNED;
    DECLARE v_id     INT UNSIGNED;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    -- 4 quarts d'heure par heure : part de la journée = profil / 809 / 4
    SET v_nb = fn_sim_arrondi(p_par_jour * fn_sim_profil_horaire(NOW()) / 809 / 4);

    WHILE v_i < v_nb DO
        SET v_i = v_i + 1;
        SET v_auteur = fn_sim_usager();
        SET v_velo = NULL;
        SET v_station = NULL;

        IF RAND() < 0.8 THEN
            SELECT FLOOR(RAND() * MAX(id_velo)) INTO v_pivot FROM velo;
            SELECT id_velo INTO v_velo
              FROM velo
             WHERE id_velo >= v_pivot AND etat_velo = 'disponible' AND id_borne IS NOT NULL
             ORDER BY id_velo LIMIT 1;
        ELSE
            SELECT id_station INTO v_station
              FROM station WHERE etat_station = 'en_service' ORDER BY RAND() LIMIT 1;
        END IF;

        IF v_auteur IS NOT NULL AND (v_velo IS NOT NULL OR v_station IS NOT NULL) THEN
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
                CALL sp_signaler_probleme(
                    v_auteur, v_velo, v_station,
                    IF(v_velo IS NOT NULL,
                       ELT(1 + FLOOR(RAND() * 6), 'Pneu crevé', 'Freins inefficaces',
                           'Chaîne qui saute', 'Selle cassée', 'Éclairage en panne',
                           'Batterie qui ne charge pas'),
                       ELT(1 + FLOOR(RAND() * 4), 'Borne qui ne libère pas le vélo',
                           'Terminal de paiement en panne', 'Station sale ou encombrée',
                           'Plan du réseau illisible')),
                    v_id);
            END;
        END IF;
    END WHILE;
END$$

-- =============================================================================
--  3. Activité des opérateurs
-- =============================================================================

-- Maintenance (jours ouvrés comme week-end, de 7 h à 19 h) :
--   - retire du réseau jusqu'à 3 vélos défectueux (les plus anciennement signalés) ;
--   - démarre la réparation des vélos en atelier depuis plus de 30 minutes ;
--   - remet en circulation, sur une borne libre, la moitié des vélos en réparation
--     depuis plus de 2 heures ;
--   - clôt les signalements de station ouverts depuis plus de 4 heures.
DROP PROCEDURE IF EXISTS sp_sim_maintenance$$
CREATE PROCEDURE sp_sim_maintenance()
corps: BEGIN
    DECLARE v_operateur    INT UNSIGNED;
    DECLARE v_id           INT UNSIGNED;
    DECLARE v_borne        INT UNSIGNED;
    DECLARE v_i            INT;
    DECLARE v_intervention INT UNSIGNED;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF HOUR(NOW()) NOT BETWEEN 7 AND 18 OR GET_LOCK('velo_sim_maintenance', 0) <> 1 THEN
        LEAVE corps;
    END IF;

    -- un opérateur de maintenance, de préférence hors comptes de démonstration
    SELECT o.id_utilisateur INTO v_operateur
      FROM operateur o JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
     WHERE o.specialite = 'maintenance'
     ORDER BY u.email LIKE '%@velo.local', RAND()
     LIMIT 1;

    IF v_operateur IS NOT NULL THEN
        -- retrait des vélos défectueux
        SET v_i = 0;
        retraits: WHILE v_i < 3 DO
            SET v_i = v_i + 1;
            SET v_id = NULL;
            SELECT v.id_velo INTO v_id
              FROM velo v
              LEFT JOIN signalement s ON s.id_velo = v.id_velo AND s.statut = 'ouvert'
             WHERE v.etat_velo = 'defectueux'
             GROUP BY v.id_velo
             ORDER BY MIN(s.date_heure) IS NULL, MIN(s.date_heure)
             LIMIT 1;
            IF v_id IS NULL THEN
                LEAVE retraits;
            END IF;
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
                CALL sp_ouvrir_intervention(v_operateur, v_id,
                     'Retrait suite à signalement : diagnostic et réparation', v_intervention);
            END;
        END WHILE;
    END IF;

    -- début des réparations
    SET v_i = 0;
    debuts: WHILE v_i < 5 DO
        SET v_i = v_i + 1;
        SET v_id = NULL;
        SELECT id_intervention INTO v_id
          FROM intervention
         WHERE date_remise_circulation IS NULL AND date_debut_reparation IS NULL
           AND date_retrait <= NOW() - INTERVAL 30 MINUTE
         ORDER BY date_retrait LIMIT 1;
        IF v_id IS NULL THEN
            LEAVE debuts;
        END IF;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_demarrer_reparation(v_id);
        END;
    END WHILE;

    -- remises en circulation (tirage d'environ la moitié des réparations éligibles)
    DROP TEMPORARY TABLE IF EXISTS sim_remise;
    CREATE TEMPORARY TABLE sim_remise (id_intervention INT UNSIGNED NOT NULL PRIMARY KEY)
        ENGINE=MEMORY;
    INSERT INTO sim_remise
    SELECT id_intervention
      FROM intervention
     WHERE date_remise_circulation IS NULL
       AND date_debut_reparation <= NOW() - INTERVAL 2 HOUR
       AND RAND() < 0.5
     LIMIT 5;

    remises: LOOP
        SET v_id = NULL;
        SELECT id_intervention INTO v_id FROM sim_remise LIMIT 1;
        IF v_id IS NULL THEN
            LEAVE remises;
        END IF;
        DELETE FROM sim_remise WHERE id_intervention = v_id;
        SET v_borne = fn_sim_borne_libre(0);
        IF v_borne IS NULL THEN
            LEAVE remises;
        END IF;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_cloturer_intervention(v_id, v_borne);
        END;
    END LOOP;
    DROP TEMPORARY TABLE sim_remise;

    -- signalements de station traités
    SET v_i = 0;
    stations: WHILE v_i < 5 DO
        SET v_i = v_i + 1;
        SET v_id = NULL;
        SELECT id_signalement INTO v_id
          FROM signalement
         WHERE statut = 'ouvert' AND id_station IS NOT NULL
           AND date_heure <= NOW() - INTERVAL 4 HOUR
         ORDER BY date_heure LIMIT 1;
        IF v_id IS NULL THEN
            LEAVE stations;
        END IF;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_cloturer_signalement(v_id);
        END;
    END WHILE;

    DO RELEASE_LOCK('velo_sim_maintenance');
END$$

-- Régulation (de 6 h à 22 h) : jusqu'à p_max_tournees tournées, chacune déplaçant
-- des vélos de la station la plus pleine (>= 80 %) vers la plus vide (sous 50 %),
-- dans la limite de la capacité du véhicule, pour ramener les deux vers 50 %.
DROP PROCEDURE IF EXISTS sp_sim_regulation$$
CREATE PROCEDURE sp_sim_regulation(IN p_max_tournees INT)
corps: BEGIN
    DECLARE v_t          INT DEFAULT 0;
    DECLARE v_pleine     INT UNSIGNED;
    DECLARE v_vide       INT UNSIGNED;
    DECLARE v_surplus    INT;
    DECLARE v_manque     INT;
    DECLARE v_operateur  INT UNSIGNED;
    DECLARE v_vehicule   INT UNSIGNED;
    DECLARE v_capacite   INT;
    DECLARE v_nb         INT;
    DECLARE v_i          INT;
    DECLARE v_velo       INT UNSIGNED;
    DECLARE v_tournee    INT UNSIGNED;
    DECLARE v_borne      INT UNSIGNED;
    DECLARE v_echec      BOOLEAN;
    -- un SELECT ... INTO sans résultat (rien à traiter) est un cas normal :
    -- sans ce gestionnaire, chaque exécution d'événement l'écrirait dans le journal
    DECLARE CONTINUE HANDLER FOR NOT FOUND BEGIN END;

    IF HOUR(NOW()) NOT BETWEEN 6 AND 21 OR GET_LOCK('velo_sim_regulation', 0) <> 1 THEN
        LEAVE corps;
    END IF;

    tournees: WHILE v_t < COALESCE(p_max_tournees, 1) DO
        SET v_t = v_t + 1;
        SET v_pleine = NULL, v_vide = NULL, v_operateur = NULL, v_vehicule = NULL;

        SELECT id_station, FLOOR(nb_velos_disponibles - nb_bornes * 0.5)
          INTO v_pleine, v_surplus
          FROM v_stations_occupation
         WHERE etat_station = 'en_service' AND nb_bornes > 0 AND taux_remplissage >= 0.8
         ORDER BY taux_remplissage DESC LIMIT 1;
        SELECT id_station, FLOOR(nb_bornes * 0.5 - nb_velos)
          INTO v_vide, v_manque
          FROM v_stations_occupation
         WHERE etat_station = 'en_service' AND nb_bornes > 0 AND taux_remplissage < 0.5
         ORDER BY taux_remplissage LIMIT 1;

        -- opérateur de régulation et véhicule libres (sans tournée en cours)
        SELECT o.id_utilisateur INTO v_operateur
          FROM operateur o JOIN utilisateur u ON u.id_utilisateur = o.id_utilisateur
         WHERE o.specialite = 'regulation'
           AND NOT EXISTS (SELECT 1 FROM tournee t
                            WHERE t.id_operateur = o.id_utilisateur AND t.date_heure_fin IS NULL)
         ORDER BY u.email LIKE '%@velo.local', RAND()
         LIMIT 1;
        SELECT id_vehicule, capacite_velos INTO v_vehicule, v_capacite
          FROM vehicule ve
         WHERE NOT EXISTS (SELECT 1 FROM tournee t
                            WHERE t.id_vehicule = ve.id_vehicule AND t.date_heure_fin IS NULL)
         ORDER BY RAND() LIMIT 1;

        SET v_nb = LEAST(COALESCE(v_surplus, 0), COALESCE(v_manque, 0), COALESCE(v_capacite, 0));
        IF v_pleine IS NULL OR v_vide IS NULL OR v_operateur IS NULL OR v_vehicule IS NULL
           OR v_nb < 1 THEN
            LEAVE tournees;
        END IF;

        SET v_tournee = NULL, v_echec = FALSE;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_echec = TRUE;
            CALL sp_demarrer_tournee(v_operateur, v_vehicule, v_tournee);
        END;
        IF v_echec OR v_tournee IS NULL THEN
            LEAVE tournees;
        END IF;

        SET v_i = 0;
        deplacements: WHILE v_i < v_nb DO
            SET v_i = v_i + 1;
            SET v_velo = NULL;
            SELECT v.id_velo INTO v_velo
              FROM velo v JOIN borne b ON b.id_borne = v.id_borne
             WHERE b.id_station = v_pleine AND v.etat_velo = 'disponible'
             LIMIT 1;
            IF v_velo IS NULL THEN
                LEAVE deplacements;
            END IF;
            BEGIN
                DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_echec = TRUE;
                CALL sp_deplacer_velo_tournee(v_tournee, v_velo, v_vide, v_borne);
            END;
            IF v_echec THEN
                LEAVE deplacements;
            END IF;
        END WHILE;

        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION BEGIN END;
            CALL sp_terminer_tournee(v_tournee);
        END;
    END WHILE;

    DO RELEASE_LOCK('velo_sim_regulation');
END$$

-- =============================================================================
--  4. Pilotage
-- =============================================================================

-- Active ou suspend tous les événements de la simulation
DROP PROCEDURE IF EXISTS sp_sim_activer$$
CREATE PROCEDURE sp_sim_activer(IN p_actif BOOLEAN)
BEGIN
    IF p_actif THEN
        ALTER EVENT ev_sim_trajets      ENABLE;
        ALTER EVENT ev_sim_abonnements  ENABLE;
        ALTER EVENT ev_sim_signalements ENABLE;
        ALTER EVENT ev_sim_maintenance  ENABLE;
        ALTER EVENT ev_sim_regulation   ENABLE;
    ELSE
        ALTER EVENT ev_sim_trajets      DISABLE;
        ALTER EVENT ev_sim_abonnements  DISABLE;
        ALTER EVENT ev_sim_signalements DISABLE;
        ALTER EVENT ev_sim_maintenance  DISABLE;
        ALTER EVENT ev_sim_regulation   DISABLE;
    END IF;
    SELECT EVENT_NAME AS evenement, STATUS AS statut, LAST_EXECUTED AS derniere_execution
      FROM information_schema.EVENTS
     WHERE EVENT_SCHEMA = DATABASE() AND EVENT_NAME LIKE 'ev\_sim\_%'
     ORDER BY EVENT_NAME;
END$$

-- Activité des p_heures dernières heures (simulée ou non), pour vérifier que la base vit
DROP PROCEDURE IF EXISTS sp_sim_bilan$$
CREATE PROCEDURE sp_sim_bilan(IN p_heures INT)
BEGIN
    DECLARE v_depuis DATETIME DEFAULT NOW() - INTERVAL COALESCE(p_heures, 24) HOUR;

    SELECT 'emprunts' AS activite, COUNT(*) AS nombre
      FROM location WHERE date_heure_emprunt >= v_depuis
    UNION ALL
    -- un trajet dure au plus 3 heures : la borne inférieure sur l'emprunt garde l'index
    SELECT 'restitutions', COUNT(*)
      FROM location
     WHERE date_heure_emprunt >= v_depuis - INTERVAL 1 DAY
       AND date_heure_restitution >= v_depuis
    UNION ALL
    SELECT 'locations en cours', COUNT(*) FROM location WHERE velo_en_cours IS NOT NULL
    UNION ALL
    SELECT 'nouveaux usagers', COUNT(*)
      FROM utilisateur u JOIN usager us ON us.id_utilisateur = u.id_utilisateur
     WHERE u.date_inscription >= v_depuis
    UNION ALL
    SELECT 'abonnements souscrits', COUNT(*) FROM abonnement WHERE date_debut >= v_depuis
    UNION ALL
    SELECT 'factures émises', COUNT(*) FROM facture WHERE date_emission >= v_depuis
    UNION ALL
    SELECT 'signalements', COUNT(*) FROM signalement WHERE date_heure >= v_depuis
    UNION ALL
    SELECT 'vélos retirés pour réparation', COUNT(*)
      FROM intervention WHERE date_retrait >= v_depuis
    UNION ALL
    SELECT 'vélos remis en circulation', COUNT(*)
      FROM intervention WHERE date_remise_circulation >= v_depuis
    UNION ALL
    SELECT 'tournées de régulation', COUNT(*) FROM tournee WHERE date_heure_debut >= v_depuis
    UNION ALL
    SELECT 'vélos déplacés', COUNT(*)
      FROM ligne_tournee WHERE date_heure_deplacement >= v_depuis
    UNION ALL
    SELECT 'relevés de stations', COUNT(*) FROM releve_station WHERE horodatage >= v_depuis;
END$$

DELIMITER ;

-- =============================================================================
--  5. Événements planifiés de la simulation
--     Intensités par défaut, adaptées à la taille de la flotte pour les trajets ;
--     à ajuster dans les appels ci-dessous puis ré-exécuter ce script.
-- =============================================================================
DROP EVENT IF EXISTS ev_sim_trajets;
CREATE EVENT ev_sim_trajets
    ON SCHEDULE EVERY 1 MINUTE
    COMMENT 'Simulation : emprunts et restitutions de la minute'
    DO CALL sp_sim_trajets(NULL, 15);           -- 1 % de la flotte par minute en pointe, 15 min

DROP EVENT IF EXISTS ev_sim_abonnements;
CREATE EVENT ev_sim_abonnements
    ON SCHEDULE EVERY 1 HOUR
    COMMENT 'Simulation : inscriptions et réabonnements'
    DO CALL sp_sim_abonnements(20, 40);         -- par jour : 20 inscriptions, 40 réabonnements

DROP EVENT IF EXISTS ev_sim_signalements;
CREATE EVENT ev_sim_signalements
    ON SCHEDULE EVERY 15 MINUTE
    COMMENT 'Simulation : signalements de vélos et de stations'
    DO CALL sp_sim_signalements(12);            -- 12 signalements par jour

DROP EVENT IF EXISTS ev_sim_maintenance;
CREATE EVENT ev_sim_maintenance
    ON SCHEDULE EVERY 15 MINUTE
    COMMENT 'Simulation : retrait, réparation et remise en circulation des vélos'
    DO CALL sp_sim_maintenance();

DROP EVENT IF EXISTS ev_sim_regulation;
CREATE EVENT ev_sim_regulation
    ON SCHEDULE EVERY 1 HOUR
    COMMENT 'Simulation : tournées de rééquilibrage'
    DO CALL sp_sim_regulation(2);               -- au plus 2 tournées par heure

SELECT IF(@@event_scheduler = 'ON',
          'Simulation installée : les événements ev_sim_* sont actifs.',
          'Simulation installée, mais event_scheduler est désactivé : SET GLOBAL event_scheduler = ON;')
       AS simulation;
