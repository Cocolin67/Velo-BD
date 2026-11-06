-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  Vue, procédures stockées et événements planifiés
--
--  À exécuter APRÈS schema.sql et triggers.sql (voir l'en-tête de triggers.sql).
--  Script ré-exécutable. Les lignes DELIMITER sont des commandes du client `mysql`.
--
--  Conventions :
--    - paramètres : p_xxx ; variables locales : v_xxx ;
--    - les erreurs métier sont levées par SIGNAL SQLSTATE '45000' avec un message
--      lisible, que l'application peut afficher tel quel ;
--    - les procédures qui modifient plusieurs tables sont transactionnelles
--      (ROLLBACK + RESIGNAL en cas d'erreur) et verrouillent les lignes utiles
--      (SELECT ... FOR UPDATE) pour résister aux accès concurrents ;
--    - l'historisation et le calcul du coût sont faits par les triggers.
--
--  Sommaire :
--    0. Vue v_stations_occupation (temps réel)
--    1. Utilisateurs         sp_inscrire_usager, sp_creer_operateur, sp_authentifier
--    2. Abonnements          sp_souscrire_abonnement, sp_renouveler_abonnement,
--                            sp_resilier_abonnement, sp_expirer_abonnements
--    3. Locations            sp_emprunter_velo, sp_rendre_velo
--    4. Facturation          sp_facturer_locations, sp_facturer_toutes_locations
--    5. Signalements         sp_signaler_probleme, sp_cloturer_signalement
--    6. Maintenance          sp_ouvrir_intervention, sp_demarrer_reparation,
--                            sp_cloturer_intervention
--    7. Régulation           sp_stations_a_reequilibrer, sp_proposer_deplacements,
--                            sp_demarrer_tournee, sp_deplacer_velo_tournee,
--                            sp_terminer_tournee, sp_releve_stations
--    8. Statistiques         sp_stat_trajets_par_periode, sp_stat_heures_pointe,
--                            sp_stat_trajets_od, sp_stat_remplissage_stations,
--                            sp_stat_recettes_par_formule, sp_stat_indisponibilite_flotte
--    9. Événements planifiés (nécessitent SET GLOBAL event_scheduler = ON)
-- =============================================================================

USE velo_libre_service;

-- -----------------------------------------------------------------------------
--  0. Occupation des stations en temps réel
--     (vélos disponibles par type, bornes libres, taux de remplissage)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_stations_occupation AS
SELECT s.id_station,
       s.nom,
       s.latitude,
       s.longitude,
       s.etat_station,
       COUNT(b.id_borne)                                                          AS nb_bornes,
       COALESCE(SUM(b.etat_borne = 'fonctionnelle' AND v.id_velo IS NULL), 0)     AS nb_bornes_libres,
       COUNT(v.id_velo)                                                           AS nb_velos,
       COALESCE(SUM(v.etat_velo = 'disponible' AND v.type_velo = 'mecanique'), 0)  AS nb_velos_mecaniques,
       COALESCE(SUM(v.etat_velo = 'disponible' AND v.type_velo = 'electrique'), 0) AS nb_velos_electriques,
       COALESCE(SUM(v.etat_velo = 'disponible'), 0)                               AS nb_velos_disponibles,
       ROUND(COUNT(v.id_velo) / NULLIF(COUNT(b.id_borne), 0), 3)                  AS taux_remplissage
  FROM station s
  LEFT JOIN borne b ON b.id_station = s.id_station
  LEFT JOIN velo  v ON v.id_borne   = b.id_borne
 GROUP BY s.id_station, s.nom, s.latitude, s.longitude, s.etat_station;

DELIMITER $$

-- =============================================================================
--  1. UTILISATEURS
-- =============================================================================

-- Inscription d'un usager (le mot de passe est déjà haché par l'application)
DROP PROCEDURE IF EXISTS sp_inscrire_usager$$
CREATE PROCEDURE sp_inscrire_usager(
    IN  p_nom            VARCHAR(100),
    IN  p_prenom         VARCHAR(100),
    IN  p_email          VARCHAR(255),
    IN  p_mdp_hash       VARCHAR(255),
    IN  p_date_naissance DATE,
    IN  p_telephone      VARCHAR(20),
    OUT p_id_utilisateur INT UNSIGNED
)
BEGIN
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        ROLLBACK;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cet email est déjà utilisé';
    END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash)
    VALUES (p_nom, p_prenom, p_email, p_mdp_hash);
    SET p_id_utilisateur = LAST_INSERT_ID();
    INSERT INTO usager (id_utilisateur, date_naissance, telephone)
    VALUES (p_id_utilisateur, p_date_naissance, p_telephone);
    COMMIT;
END$$

-- Création d'un opérateur (régulation ou maintenance), éventuellement administrateur
DROP PROCEDURE IF EXISTS sp_creer_operateur$$
CREATE PROCEDURE sp_creer_operateur(
    IN  p_nom            VARCHAR(100),
    IN  p_prenom         VARCHAR(100),
    IN  p_email          VARCHAR(255),
    IN  p_mdp_hash       VARCHAR(255),
    IN  p_matricule      VARCHAR(20),
    IN  p_specialite     VARCHAR(20),     -- 'regulation' ou 'maintenance'
    IN  p_est_admin      BOOLEAN,
    OUT p_id_utilisateur INT UNSIGNED
)
BEGIN
    DECLARE EXIT HANDLER FOR 1062
    BEGIN
        ROLLBACK;
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Email ou matricule déjà utilisé';
    END;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF p_specialite NOT IN ('regulation', 'maintenance') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Spécialité invalide (regulation ou maintenance)';
    END IF;

    START TRANSACTION;
    INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash)
    VALUES (p_nom, p_prenom, p_email, p_mdp_hash);
    SET p_id_utilisateur = LAST_INSERT_ID();
    INSERT INTO operateur (id_utilisateur, matricule, specialite)
    VALUES (p_id_utilisateur, p_matricule, p_specialite);
    IF p_est_admin THEN
        INSERT INTO administrateur (id_utilisateur) VALUES (p_id_utilisateur);
    END IF;
    COMMIT;
END$$

-- Authentification : renvoie le hash et le rôle ; l'application compare le mot de passe
-- (aucune ligne si l'email est inconnu)
DROP PROCEDURE IF EXISTS sp_authentifier$$
CREATE PROCEDURE sp_authentifier(IN p_email VARCHAR(255))
BEGIN
    SELECT u.id_utilisateur,
           u.nom,
           u.prenom,
           u.mot_de_passe_hash,
           CASE WHEN a.id_utilisateur  IS NOT NULL THEN 'administrateur'
                WHEN o.id_utilisateur  IS NOT NULL THEN 'operateur'
                WHEN us.id_utilisateur IS NOT NULL THEN 'usager'
           END AS role,
           o.specialite
      FROM utilisateur u
      LEFT JOIN usager         us ON us.id_utilisateur = u.id_utilisateur
      LEFT JOIN operateur      o  ON o.id_utilisateur  = u.id_utilisateur
      LEFT JOIN administrateur a  ON a.id_utilisateur  = u.id_utilisateur
     WHERE u.email = p_email;
END$$

-- =============================================================================
--  2. ABONNEMENTS
-- =============================================================================

-- Souscription : crée l'abonnement (de maintenant à + durée de la formule) et sa facture
DROP PROCEDURE IF EXISTS sp_souscrire_abonnement$$
CREATE PROCEDURE sp_souscrire_abonnement(
    IN  p_id_usager           INT UNSIGNED,
    IN  p_id_formule          INT UNSIGNED,
    IN  p_renouvellement_auto BOOLEAN,
    OUT p_id_abonnement       INT UNSIGNED,
    OUT p_id_facture          INT UNSIGNED
)
BEGIN
    DECLARE v_prix  DECIMAL(8, 2);
    DECLARE v_jours SMALLINT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    IF NOT EXISTS (SELECT 1 FROM usager WHERE id_utilisateur = p_id_usager) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Usager inconnu';
    END IF;

    SELECT prix, duree_validite_jours INTO v_prix, v_jours
      FROM formule WHERE id_formule = p_id_formule;
    IF v_prix IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Formule inconnue';
    END IF;

    IF EXISTS (SELECT 1 FROM abonnement
                WHERE id_utilisateur = p_id_usager AND statut = 'actif' AND date_fin > NOW()) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Abonnement déjà en cours : utiliser sp_renouveler_abonnement';
    END IF;

    START TRANSACTION;
    INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, renouvellement_auto)
    VALUES (p_id_usager, p_id_formule, NOW(), DATE_ADD(NOW(), INTERVAL v_jours DAY),
            COALESCE(p_renouvellement_auto, FALSE));
    SET p_id_abonnement = LAST_INSERT_ID();
    INSERT INTO facture (id_abonnement, montant_total) VALUES (p_id_abonnement, v_prix);
    SET p_id_facture = LAST_INSERT_ID();
    COMMIT;
END$$

-- Renouvellement : nouvel abonnement (même formule) qui commence à la fin de l'ancien
-- (ou maintenant si l'ancien est déjà échu) ; la facture est émise immédiatement.
DROP PROCEDURE IF EXISTS sp_renouveler_abonnement$$
CREATE PROCEDURE sp_renouveler_abonnement(
    IN  p_id_abonnement INT UNSIGNED,
    OUT p_id_nouveau    INT UNSIGNED,
    OUT p_id_facture    INT UNSIGNED
)
BEGIN
    DECLARE v_usager  INT UNSIGNED;
    DECLARE v_formule INT UNSIGNED;
    DECLARE v_statut  VARCHAR(10);
    DECLARE v_fin     DATETIME;
    DECLARE v_auto    BOOLEAN;
    DECLARE v_prix    DECIMAL(8, 2);
    DECLARE v_jours   SMALLINT UNSIGNED;
    DECLARE v_debut   DATETIME;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT id_utilisateur, id_formule, statut, date_fin, renouvellement_auto
      INTO v_usager, v_formule, v_statut, v_fin, v_auto
      FROM abonnement WHERE id_abonnement = p_id_abonnement FOR UPDATE;

    IF v_usager IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Abonnement inconnu';
    END IF;
    IF v_statut = 'resilie' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Un abonnement résilié ne peut pas être renouvelé';
    END IF;

    SELECT prix, duree_validite_jours INTO v_prix, v_jours FROM formule WHERE id_formule = v_formule;
    SET v_debut = GREATEST(v_fin, NOW());

    INSERT INTO abonnement (id_utilisateur, id_formule, date_debut, date_fin, renouvellement_auto)
    VALUES (v_usager, v_formule, v_debut, DATE_ADD(v_debut, INTERVAL v_jours DAY), v_auto);
    SET p_id_nouveau = LAST_INSERT_ID();

    INSERT INTO facture (id_abonnement, montant_total) VALUES (p_id_nouveau, v_prix);
    SET p_id_facture = LAST_INSERT_ID();

    -- l'ancien abonnement ne doit plus se renouveler une seconde fois
    UPDATE abonnement SET renouvellement_auto = FALSE WHERE id_abonnement = p_id_abonnement;
    COMMIT;
END$$

-- Résiliation : arrête l'abonnement dès maintenant (refusée si un vélo est en cours d'emprunt)
DROP PROCEDURE IF EXISTS sp_resilier_abonnement$$
CREATE PROCEDURE sp_resilier_abonnement(IN p_id_abonnement INT UNSIGNED)
BEGIN
    DECLARE v_statut VARCHAR(10);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT statut INTO v_statut FROM abonnement WHERE id_abonnement = p_id_abonnement FOR UPDATE;
    IF v_statut IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Abonnement inconnu';
    END IF;
    IF v_statut = 'resilie' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Abonnement déjà résilié';
    END IF;
    IF EXISTS (SELECT 1 FROM location
                WHERE id_abonnement = p_id_abonnement AND date_heure_restitution IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Résiliation impossible : un vélo est en cours de location';
    END IF;

    UPDATE abonnement
       SET statut = 'resilie',
           renouvellement_auto = FALSE,
           date_fin = IF(NOW() > date_debut, LEAST(date_fin, NOW()), date_fin)
     WHERE id_abonnement = p_id_abonnement;
    COMMIT;
END$$

-- Tâche périodique : renouvelle les abonnements échus en renouvellement automatique,
-- puis marque comme expirés tous les abonnements échus.
DROP PROCEDURE IF EXISTS sp_expirer_abonnements$$
CREATE PROCEDURE sp_expirer_abonnements()
BEGIN
    DECLARE v_id          INT UNSIGNED;
    DECLARE v_nouveau     INT UNSIGNED;
    DECLARE v_facture     INT UNSIGNED;
    DECLARE v_renouveles  INT DEFAULT 0;
    DECLARE v_erreurs     INT DEFAULT 0;
    DECLARE v_expires     INT DEFAULT 0;
    DECLARE v_fini        BOOLEAN DEFAULT FALSE;
    DECLARE c_echus CURSOR FOR
        SELECT id_abonnement FROM abonnement
         WHERE statut = 'actif' AND date_fin <= NOW() AND renouvellement_auto = TRUE;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fini = TRUE;

    OPEN c_echus;
    boucle: LOOP
        FETCH c_echus INTO v_id;
        IF v_fini THEN
            LEAVE boucle;
        END IF;
        BEGIN
            -- une erreur sur un abonnement ne bloque pas les autres
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_erreurs = v_erreurs + 1;
            CALL sp_renouveler_abonnement(v_id, v_nouveau, v_facture);
            IF v_nouveau IS NOT NULL THEN
                SET v_renouveles = v_renouveles + 1;
            END IF;
            SET v_nouveau = NULL;
        END;
    END LOOP;
    CLOSE c_echus;

    UPDATE abonnement SET statut = 'expire' WHERE statut = 'actif' AND date_fin <= NOW();
    SET v_expires = ROW_COUNT();

    SELECT v_expires AS abonnements_expires, v_renouveles AS renouvellements, v_erreurs AS erreurs;
END$$

-- =============================================================================
--  3. LOCATIONS
-- =============================================================================

-- Emprunt d'un vélo posé sur une borne.
-- Règles : abonnement valide, un seul vélo à la fois, vélo disponible (non défectueux),
-- borne et station en service. L'historisation est faite par trg_velo_au.
DROP PROCEDURE IF EXISTS sp_emprunter_velo$$
CREATE PROCEDURE sp_emprunter_velo(
    IN  p_id_usager   INT UNSIGNED,
    IN  p_id_velo     INT UNSIGNED,
    OUT p_id_location BIGINT UNSIGNED
)
BEGIN
    DECLARE v_abonnement   INT UNSIGNED;
    DECLARE v_etat         VARCHAR(12);
    DECLARE v_borne        INT UNSIGNED;
    DECLARE v_etat_borne   VARCHAR(15);
    DECLARE v_etat_station VARCHAR(15);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT id_abonnement INTO v_abonnement
      FROM abonnement
     WHERE id_utilisateur = p_id_usager
       AND statut = 'actif'
       AND date_debut <= NOW() AND date_fin > NOW()
     ORDER BY date_fin DESC
     LIMIT 1
       FOR UPDATE;
    IF v_abonnement IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aucun abonnement valide pour cet usager';
    END IF;

    SELECT etat_velo, id_borne INTO v_etat, v_borne
      FROM velo WHERE id_velo = p_id_velo FOR UPDATE;
    IF v_etat IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vélo inconnu';
    ELSEIF v_etat = 'defectueux' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vélo signalé défectueux : emprunt impossible';
    ELSEIF v_etat <> 'disponible' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vélo indisponible (en location ou en atelier)';
    END IF;
    IF v_borne IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ce vélo n''est sur aucune borne';
    END IF;

    SELECT b.etat_borne, s.etat_station INTO v_etat_borne, v_etat_station
      FROM borne b JOIN station s ON s.id_station = b.id_station
     WHERE b.id_borne = v_borne;
    IF v_etat_borne <> 'fonctionnelle' OR v_etat_station <> 'en_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borne ou station hors service';
    END IF;

    -- trg_location_bi revérifie : abonnement valide, un seul vélo par usager, vélo disponible
    INSERT INTO location (id_abonnement, id_velo, id_borne_depart, date_heure_emprunt)
    VALUES (v_abonnement, p_id_velo, v_borne, NOW());
    SET p_id_location = LAST_INSERT_ID();

    UPDATE velo SET etat_velo = 'en_location', id_borne = NULL WHERE id_velo = p_id_velo;
    COMMIT;
END$$

-- Restitution du vélo en cours de l'usager sur une borne libre.
-- La durée est calculée par la base, le coût par trg_location_bu (fn_calculer_cout).
-- Si le vélo a été signalé pendant la location, il passe en « défectueux ».
DROP PROCEDURE IF EXISTS sp_rendre_velo$$
CREATE PROCEDURE sp_rendre_velo(
    IN  p_id_usager   INT UNSIGNED,
    IN  p_id_borne    INT UNSIGNED,
    OUT p_id_location BIGINT UNSIGNED,
    OUT p_duree_min   INT UNSIGNED,
    OUT p_cout        DECIMAL(8, 2)
)
BEGIN
    DECLARE v_velo         INT UNSIGNED;
    DECLARE v_etat_borne   VARCHAR(15);
    DECLARE v_etat_station VARCHAR(15);
    DECLARE v_signale      INT;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;

    SELECT l.id_location, l.id_velo INTO p_id_location, v_velo
      FROM location l
      JOIN abonnement a ON a.id_abonnement = l.id_abonnement
     WHERE a.id_utilisateur = p_id_usager AND l.date_heure_restitution IS NULL
     LIMIT 1
       FOR UPDATE;
    IF p_id_location IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aucune location en cours pour cet usager';
    END IF;

    SELECT etat_borne INTO v_etat_borne FROM borne WHERE id_borne = p_id_borne FOR UPDATE;
    IF v_etat_borne IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borne inconnue';
    END IF;
    SELECT s.etat_station INTO v_etat_station
      FROM borne b JOIN station s ON s.id_station = b.id_station WHERE b.id_borne = p_id_borne;
    IF v_etat_borne <> 'fonctionnelle' OR v_etat_station <> 'en_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borne ou station hors service';
    END IF;
    IF EXISTS (SELECT 1 FROM velo WHERE id_borne = p_id_borne) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cette borne est déjà occupée';
    END IF;

    UPDATE location
       SET date_heure_restitution = NOW(), id_borne_arrivee = p_id_borne
     WHERE id_location = p_id_location;

    SELECT COUNT(*) INTO v_signale
      FROM signalement WHERE id_velo = v_velo AND statut IN ('ouvert', 'pris_en_charge');

    UPDATE velo
       SET etat_velo = IF(v_signale > 0, 'defectueux', 'disponible'), id_borne = p_id_borne
     WHERE id_velo = v_velo;

    SELECT duree_min, cout INTO p_duree_min, p_cout FROM location WHERE id_location = p_id_location;
    COMMIT;
END$$

-- =============================================================================
--  4. FACTURATION
-- =============================================================================

-- Regroupe en une facture les trajets terminés et non encore facturés d'un abonnement
-- (seuls les trajets de coût > 0 sont facturés). p_id_facture vaut NULL s'il n'y a rien à facturer.
DROP PROCEDURE IF EXISTS sp_facturer_locations$$
CREATE PROCEDURE sp_facturer_locations(
    IN  p_id_abonnement INT UNSIGNED,
    OUT p_id_facture    INT UNSIGNED
)
BEGIN
    DECLARE v_total DECIMAL(10, 2);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SET p_id_facture = NULL;
    START TRANSACTION;
    SELECT COALESCE(SUM(cout), 0) INTO v_total
      FROM location
     WHERE id_abonnement = p_id_abonnement
       AND id_facture IS NULL AND date_heure_restitution IS NOT NULL AND cout > 0
       FOR UPDATE;

    IF v_total > 0 THEN
        INSERT INTO facture (id_abonnement, montant_total) VALUES (p_id_abonnement, v_total);
        SET p_id_facture = LAST_INSERT_ID();
        UPDATE location SET id_facture = p_id_facture
         WHERE id_abonnement = p_id_abonnement
           AND id_facture IS NULL AND date_heure_restitution IS NOT NULL AND cout > 0;
    END IF;
    COMMIT;
END$$

-- Tâche périodique : facture les trajets en attente de tous les abonnements
DROP PROCEDURE IF EXISTS sp_facturer_toutes_locations$$
CREATE PROCEDURE sp_facturer_toutes_locations()
BEGIN
    DECLARE v_id       INT UNSIGNED;
    DECLARE v_facture  INT UNSIGNED;
    DECLARE v_nb       INT DEFAULT 0;
    DECLARE v_erreurs  INT DEFAULT 0;
    DECLARE v_fini     BOOLEAN DEFAULT FALSE;
    DECLARE c_abos CURSOR FOR
        SELECT DISTINCT id_abonnement FROM location
         WHERE id_facture IS NULL AND date_heure_restitution IS NOT NULL AND cout > 0;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fini = TRUE;

    OPEN c_abos;
    boucle: LOOP
        FETCH c_abos INTO v_id;
        IF v_fini THEN
            LEAVE boucle;
        END IF;
        BEGIN
            DECLARE CONTINUE HANDLER FOR SQLEXCEPTION SET v_erreurs = v_erreurs + 1;
            SET v_facture = NULL;
            CALL sp_facturer_locations(v_id, v_facture);
            IF v_facture IS NOT NULL THEN
                SET v_nb = v_nb + 1;
            END IF;
        END;
    END LOOP;
    CLOSE c_abos;

    SELECT v_nb AS factures_emises, v_erreurs AS erreurs;
END$$

-- =============================================================================
--  5. SIGNALEMENTS
-- =============================================================================

-- Signale un problème sur un vélo OU une station (l'un des deux, jamais les deux).
-- Un vélo disponible signalé passe en « défectueux » (trigger trg_signalement_ai).
DROP PROCEDURE IF EXISTS sp_signaler_probleme$$
CREATE PROCEDURE sp_signaler_probleme(
    IN  p_id_utilisateur INT UNSIGNED,
    IN  p_id_velo        INT UNSIGNED,     -- NULL si le signalement vise une station
    IN  p_id_station     INT UNSIGNED,     -- NULL si le signalement vise un vélo
    IN  p_description    TEXT,
    OUT p_id_signalement INT UNSIGNED
)
BEGIN
    IF (p_id_velo IS NULL) = (p_id_station IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Un signalement vise soit un vélo, soit une station';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM utilisateur WHERE id_utilisateur = p_id_utilisateur) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Utilisateur inconnu';
    END IF;

    INSERT INTO signalement (id_utilisateur, id_velo, id_station, description)
    VALUES (p_id_utilisateur, p_id_velo, p_id_station, p_description);
    SET p_id_signalement = LAST_INSERT_ID();
END$$

-- Clôture un signalement (fausse alerte ou problème réglé). Si le vélo était bloqué
-- uniquement à cause de lui, il est remis en service sur sa borne.
DROP PROCEDURE IF EXISTS sp_cloturer_signalement$$
CREATE PROCEDURE sp_cloturer_signalement(IN p_id_signalement INT UNSIGNED)
BEGIN
    DECLARE v_velo   INT UNSIGNED;
    DECLARE v_statut VARCHAR(15);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT id_velo, statut INTO v_velo, v_statut
      FROM signalement WHERE id_signalement = p_id_signalement FOR UPDATE;
    IF v_statut IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Signalement inconnu';
    END IF;
    IF v_statut = 'clos' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Signalement déjà clos';
    END IF;

    UPDATE signalement SET statut = 'clos' WHERE id_signalement = p_id_signalement;

    IF v_velo IS NOT NULL
       AND NOT EXISTS (SELECT 1 FROM signalement
                        WHERE id_velo = v_velo AND statut IN ('ouvert', 'pris_en_charge'))
       AND NOT EXISTS (SELECT 1 FROM intervention
                        WHERE id_velo = v_velo AND date_remise_circulation IS NULL) THEN
        UPDATE velo SET etat_velo = 'disponible'
         WHERE id_velo = v_velo AND etat_velo = 'defectueux' AND id_borne IS NOT NULL;
    END IF;
    COMMIT;
END$$

-- =============================================================================
--  6. MAINTENANCE
-- =============================================================================

-- Retire un vélo du réseau pour réparation. Réservé aux opérateurs de maintenance
-- (et aux administrateurs). Les signalements ouverts du vélo sont rattachés à l'intervention.
DROP PROCEDURE IF EXISTS sp_ouvrir_intervention$$
CREATE PROCEDURE sp_ouvrir_intervention(
    IN  p_id_operateur    INT UNSIGNED,
    IN  p_id_velo         INT UNSIGNED,
    IN  p_description     TEXT,
    OUT p_id_intervention INT UNSIGNED
)
BEGIN
    DECLARE v_specialite VARCHAR(15);
    DECLARE v_etat       VARCHAR(12);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    SELECT specialite INTO v_specialite FROM operateur WHERE id_utilisateur = p_id_operateur;
    IF v_specialite IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Opérateur inconnu';
    END IF;
    IF v_specialite <> 'maintenance'
       AND NOT EXISTS (SELECT 1 FROM administrateur WHERE id_utilisateur = p_id_operateur) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Seuls les opérateurs de maintenance peuvent ouvrir une intervention';
    END IF;

    START TRANSACTION;
    SELECT etat_velo INTO v_etat FROM velo WHERE id_velo = p_id_velo FOR UPDATE;
    IF v_etat IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vélo inconnu';
    ELSEIF v_etat = 'en_location' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ce vélo est actuellement en location';
    ELSEIF v_etat = 'en_atelier' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Ce vélo est déjà en atelier';
    END IF;

    INSERT INTO intervention (id_velo, id_operateur, date_retrait, description_travaux)
    VALUES (p_id_velo, p_id_operateur, NOW(), p_description);
    SET p_id_intervention = LAST_INSERT_ID();

    UPDATE velo SET etat_velo = 'en_atelier', id_borne = NULL WHERE id_velo = p_id_velo;

    UPDATE signalement
       SET id_intervention = p_id_intervention, statut = 'pris_en_charge'
     WHERE id_velo = p_id_velo AND statut IN ('ouvert', 'pris_en_charge') AND id_intervention IS NULL;
    COMMIT;
END$$

-- Début effectif de la réparation
DROP PROCEDURE IF EXISTS sp_demarrer_reparation$$
CREATE PROCEDURE sp_demarrer_reparation(IN p_id_intervention INT UNSIGNED)
BEGIN
    UPDATE intervention
       SET date_debut_reparation = NOW()
     WHERE id_intervention = p_id_intervention
       AND date_debut_reparation IS NULL
       AND date_remise_circulation IS NULL;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Intervention inconnue, déjà démarrée ou déjà terminée';
    END IF;
END$$

-- Remise en circulation : le vélo est posé sur une borne libre et les signalements liés sont clos
DROP PROCEDURE IF EXISTS sp_cloturer_intervention$$
CREATE PROCEDURE sp_cloturer_intervention(
    IN p_id_intervention INT UNSIGNED,
    IN p_id_borne        INT UNSIGNED
)
BEGIN
    DECLARE v_velo         INT UNSIGNED;
    DECLARE v_remise       DATETIME;
    DECLARE v_etat_velo    VARCHAR(12);
    DECLARE v_etat_borne   VARCHAR(15);
    DECLARE v_etat_station VARCHAR(15);
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT id_velo, date_remise_circulation INTO v_velo, v_remise
      FROM intervention WHERE id_intervention = p_id_intervention FOR UPDATE;
    IF v_velo IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Intervention inconnue';
    END IF;
    IF v_remise IS NOT NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Intervention déjà clôturée';
    END IF;

    SELECT etat_velo INTO v_etat_velo FROM velo WHERE id_velo = v_velo FOR UPDATE;
    IF v_etat_velo <> 'en_atelier' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Le vélo n''est pas en atelier';
    END IF;

    SELECT etat_borne INTO v_etat_borne FROM borne WHERE id_borne = p_id_borne FOR UPDATE;
    IF v_etat_borne IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borne inconnue';
    END IF;
    SELECT s.etat_station INTO v_etat_station
      FROM borne b JOIN station s ON s.id_station = b.id_station WHERE b.id_borne = p_id_borne;
    IF v_etat_borne <> 'fonctionnelle' OR v_etat_station <> 'en_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Borne ou station hors service';
    END IF;
    IF EXISTS (SELECT 1 FROM velo WHERE id_borne = p_id_borne) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Cette borne est déjà occupée';
    END IF;

    UPDATE intervention SET date_remise_circulation = NOW() WHERE id_intervention = p_id_intervention;
    UPDATE signalement SET statut = 'clos' WHERE id_intervention = p_id_intervention;
    UPDATE velo SET etat_velo = 'disponible', id_borne = p_id_borne WHERE id_velo = v_velo;
    COMMIT;
END$$

-- =============================================================================
--  7. RÉGULATION DU RÉSEAU
-- =============================================================================

-- Stations vides ou pleines. Seuils en proportion (ex. 0.20 et 0.80).
DROP PROCEDURE IF EXISTS sp_stations_a_reequilibrer$$
CREATE PROCEDURE sp_stations_a_reequilibrer(
    IN p_seuil_bas  DECIMAL(4, 3),
    IN p_seuil_haut DECIMAL(4, 3)
)
BEGIN
    SELECT id_station, nom, nb_bornes, nb_velos, nb_velos_disponibles, nb_bornes_libres,
           taux_remplissage,
           IF(taux_remplissage <= p_seuil_bas, 'vide', 'pleine') AS situation
      FROM v_stations_occupation
     WHERE etat_station = 'en_service'
       AND nb_bornes > 0
       AND (taux_remplissage <= p_seuil_bas OR taux_remplissage >= p_seuil_haut)
     ORDER BY taux_remplissage;
END$$

-- Propose des déplacements : pour chaque station pleine, la station vide la plus proche
-- (distance à vol d'oiseau) et le nombre de vélos à déplacer pour viser 50 % de remplissage.
-- Proposition indicative : chaque station pleine est associée à sa seule station vide la plus proche.
DROP PROCEDURE IF EXISTS sp_proposer_deplacements$$
CREATE PROCEDURE sp_proposer_deplacements(
    IN p_seuil_bas  DECIMAL(4, 3),
    IN p_seuil_haut DECIMAL(4, 3)
)
BEGIN
    WITH occ AS (
        SELECT * FROM v_stations_occupation WHERE etat_station = 'en_service' AND nb_bornes > 0
    ),
    paires AS (
        SELECT s.id_station AS id_station_depart,  s.nom AS station_depart,
               d.id_station AS id_station_arrivee, d.nom AS station_arrivee,
               LEAST(FLOOR(s.nb_velos_disponibles - s.nb_bornes * 0.5),
                     FLOOR(d.nb_bornes * 0.5 - d.nb_velos))                       AS nb_velos_a_deplacer,
               ROUND(6371 * 2 * ASIN(SQRT(
                   POW(SIN(RADIANS(d.latitude - s.latitude) / 2), 2)
                   + COS(RADIANS(s.latitude)) * COS(RADIANS(d.latitude))
                     * POW(SIN(RADIANS(d.longitude - s.longitude) / 2), 2))), 2) AS distance_km
          FROM occ s
          JOIN occ d ON d.taux_remplissage <= p_seuil_bas
         WHERE s.taux_remplissage >= p_seuil_haut
    ),
    classees AS (
        SELECT *, ROW_NUMBER() OVER (PARTITION BY id_station_depart ORDER BY distance_km) AS rang
          FROM paires
         WHERE nb_velos_a_deplacer > 0
    )
    SELECT id_station_depart, station_depart, id_station_arrivee, station_arrivee,
           nb_velos_a_deplacer, distance_km
      FROM classees
     WHERE rang = 1
     ORDER BY nb_velos_a_deplacer DESC, distance_km;
END$$

-- Démarre une tournée (opérateur de régulation ou administrateur, une seule tournée ouverte à la fois)
DROP PROCEDURE IF EXISTS sp_demarrer_tournee$$
CREATE PROCEDURE sp_demarrer_tournee(
    IN  p_id_operateur INT UNSIGNED,
    IN  p_id_vehicule  INT UNSIGNED,
    OUT p_id_tournee   INT UNSIGNED
)
BEGIN
    DECLARE v_specialite VARCHAR(15);

    SELECT specialite INTO v_specialite FROM operateur WHERE id_utilisateur = p_id_operateur;
    IF v_specialite IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Opérateur inconnu';
    END IF;
    IF v_specialite <> 'regulation'
       AND NOT EXISTS (SELECT 1 FROM administrateur WHERE id_utilisateur = p_id_operateur) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Seuls les opérateurs de régulation peuvent faire une tournée';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vehicule WHERE id_vehicule = p_id_vehicule) THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Véhicule inconnu';
    END IF;
    IF EXISTS (SELECT 1 FROM tournee
                WHERE (id_operateur = p_id_operateur OR id_vehicule = p_id_vehicule)
                  AND date_heure_fin IS NULL) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cet opérateur ou ce véhicule a déjà une tournée en cours';
    END IF;

    INSERT INTO tournee (id_operateur, id_vehicule, date_heure_debut)
    VALUES (p_id_operateur, p_id_vehicule, NOW());
    SET p_id_tournee = LAST_INSERT_ID();
END$$

-- Déplace un vélo disponible vers une station : il est posé sur la première borne libre
-- (numéro le plus bas) et le déplacement est enregistré dans la tournée.
DROP PROCEDURE IF EXISTS sp_deplacer_velo_tournee$$
CREATE PROCEDURE sp_deplacer_velo_tournee(
    IN  p_id_tournee         INT UNSIGNED,
    IN  p_id_velo            INT UNSIGNED,
    IN  p_id_station_arrivee INT UNSIGNED,
    OUT p_id_borne_arrivee   INT UNSIGNED
)
BEGIN
    DECLARE v_ouverte        INT;
    DECLARE v_etat           VARCHAR(12);
    DECLARE v_borne_depart   INT UNSIGNED;
    DECLARE v_station_depart INT UNSIGNED;
    DECLARE v_etat_station   VARCHAR(15);
    DECLARE v_num            SMALLINT UNSIGNED;
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        RESIGNAL;
    END;

    START TRANSACTION;
    SELECT COUNT(*) INTO v_ouverte
      FROM tournee WHERE id_tournee = p_id_tournee AND date_heure_fin IS NULL FOR UPDATE;
    IF v_ouverte = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Tournée inconnue ou terminée';
    END IF;

    SELECT etat_velo, id_borne INTO v_etat, v_borne_depart
      FROM velo WHERE id_velo = p_id_velo FOR UPDATE;
    IF v_etat IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Vélo inconnu';
    END IF;
    IF v_etat <> 'disponible' OR v_borne_depart IS NULL THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Seul un vélo disponible posé sur une borne peut être déplacé';
    END IF;

    SELECT id_station INTO v_station_depart FROM borne WHERE id_borne = v_borne_depart;
    IF v_station_depart = p_id_station_arrivee THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Les stations de départ et d''arrivée sont identiques';
    END IF;

    SELECT etat_station INTO v_etat_station FROM station WHERE id_station = p_id_station_arrivee;
    IF v_etat_station IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Station d''arrivée inconnue';
    ELSEIF v_etat_station <> 'en_service' THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Station d''arrivée hors service';
    END IF;

    SELECT b.id_borne INTO p_id_borne_arrivee
      FROM borne b
      LEFT JOIN velo v ON v.id_borne = b.id_borne
     WHERE b.id_station = p_id_station_arrivee
       AND b.etat_borne = 'fonctionnelle'
       AND v.id_velo IS NULL
     ORDER BY b.num_borne
     LIMIT 1
       FOR UPDATE;
    IF p_id_borne_arrivee IS NULL THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Aucune borne libre à la station d''arrivée';
    END IF;

    UPDATE velo SET id_borne = p_id_borne_arrivee WHERE id_velo = p_id_velo;

    SELECT COALESCE(MAX(num_ligne), 0) + 1 INTO v_num
      FROM ligne_tournee WHERE id_tournee = p_id_tournee;
    INSERT INTO ligne_tournee (id_tournee, num_ligne, id_velo, id_station_depart,
                               id_station_arrivee, date_heure_deplacement)
    VALUES (p_id_tournee, v_num, p_id_velo, v_station_depart, p_id_station_arrivee, NOW());
    COMMIT;
END$$

DROP PROCEDURE IF EXISTS sp_terminer_tournee$$
CREATE PROCEDURE sp_terminer_tournee(IN p_id_tournee INT UNSIGNED)
BEGIN
    UPDATE tournee SET date_heure_fin = NOW()
     WHERE id_tournee = p_id_tournee AND date_heure_fin IS NULL;
    IF ROW_COUNT() = 0 THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Tournée inconnue ou déjà terminée';
    END IF;
END$$

-- Instantané du remplissage de toutes les stations (alimente RELEVE_STATION)
DROP PROCEDURE IF EXISTS sp_releve_stations$$
CREATE PROCEDURE sp_releve_stations()
BEGIN
    INSERT IGNORE INTO releve_station
           (id_station, horodatage, nb_velos_mecaniques, nb_velos_electriques, nb_bornes_libres)
    SELECT id_station, NOW(), nb_velos_mecaniques, nb_velos_electriques, nb_bornes_libres
      FROM v_stations_occupation;
    SELECT ROW_COUNT() AS stations_relevees;
END$$

-- =============================================================================
--  8. STATISTIQUES (période : p_debut inclus, p_fin exclu)
-- =============================================================================

-- Nombre de trajets, durée moyenne et coût par jour, semaine ISO ou mois
DROP PROCEDURE IF EXISTS sp_stat_trajets_par_periode$$
CREATE PROCEDURE sp_stat_trajets_par_periode(
    IN p_debut        DATETIME,
    IN p_fin          DATETIME,
    IN p_granularite  VARCHAR(10)      -- 'jour', 'semaine' ou 'mois'
)
BEGIN
    IF p_granularite NOT IN ('jour', 'semaine', 'mois') THEN
        SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'Granularité invalide (jour, semaine ou mois)';
    END IF;

    SELECT CASE p_granularite
               WHEN 'jour'    THEN DATE_FORMAT(date_heure_emprunt, '%Y-%m-%d')
               WHEN 'semaine' THEN DATE_FORMAT(date_heure_emprunt, '%x-S%v')
               ELSE                DATE_FORMAT(date_heure_emprunt, '%Y-%m')
           END                         AS periode,
           COUNT(*)                    AS nb_trajets,
           ROUND(AVG(duree_min), 1)    AS duree_moyenne_min,
           COALESCE(SUM(cout), 0)      AS cout_total
      FROM location
     WHERE date_heure_emprunt >= p_debut AND date_heure_emprunt < p_fin
       AND date_heure_restitution IS NOT NULL
     GROUP BY periode
     ORDER BY periode;
END$$

-- Heures de pointe : nombre de trajets par heure de départ et classement
DROP PROCEDURE IF EXISTS sp_stat_heures_pointe$$
CREATE PROCEDURE sp_stat_heures_pointe(IN p_debut DATETIME, IN p_fin DATETIME)
BEGIN
    SELECT HOUR(date_heure_emprunt)                  AS heure,
           COUNT(*)                                  AS nb_trajets,
           RANK() OVER (ORDER BY COUNT(*) DESC)      AS rang
      FROM location
     WHERE date_heure_emprunt >= p_debut AND date_heure_emprunt < p_fin
     GROUP BY HOUR(date_heure_emprunt)
     ORDER BY heure;
END$$

-- Trajets origine-destination les plus fréquents (entre stations)
--
-- Optimisation : STRAIGHT_JOIN impose de partir des LOCATIONS de la période (plage sur
-- l'index couvrant idx_loc_emprunt) puis de remonter aux bornes par clé primaire.
-- Laissé libre, l'optimiseur partait de station -> borne -> location (index des
-- arrivées) et parcourait les 5 M de locations (plus de 60 s sur la base complète).
-- Le regroupement se fait sur les seuls identifiants de stations (au plus 300² groupes,
-- table temporaire en mémoire) ; les noms ne sont joints qu'au résultat agrégé.
DROP PROCEDURE IF EXISTS sp_stat_trajets_od$$
CREATE PROCEDURE sp_stat_trajets_od(IN p_debut DATETIME, IN p_fin DATETIME, IN p_limite INT)
BEGIN
    SELECT sd.id_station AS id_station_depart,  sd.nom AS station_depart,
           sa.id_station AS id_station_arrivee, sa.nom AS station_arrivee,
           x.nb_trajets,
           ROUND(x.duree_moyenne_min, 1) AS duree_moyenne_min
      FROM (SELECT STRAIGHT_JOIN
                   bd.id_station AS id_depart,
                   ba.id_station AS id_arrivee,
                   COUNT(*)          AS nb_trajets,
                   AVG(l.duree_min)  AS duree_moyenne_min
              FROM location l
              JOIN borne bd ON bd.id_borne = l.id_borne_depart
              JOIN borne ba ON ba.id_borne = l.id_borne_arrivee
             WHERE l.date_heure_emprunt >= p_debut AND l.date_heure_emprunt < p_fin
             GROUP BY bd.id_station, ba.id_station) x
      JOIN station sd ON sd.id_station = x.id_depart
      JOIN station sa ON sa.id_station = x.id_arrivee
     ORDER BY x.nb_trajets DESC, sd.nom, sa.nom
     LIMIT p_limite;
END$$

-- Taux de remplissage moyen de chaque station par heure de la journée (d'après RELEVE_STATION).
-- Taux = vélos disponibles / (vélos disponibles + bornes libres).
DROP PROCEDURE IF EXISTS sp_stat_remplissage_stations$$
CREATE PROCEDURE sp_stat_remplissage_stations(IN p_debut DATETIME, IN p_fin DATETIME)
BEGIN
    SELECT s.id_station,
           s.nom,
           HOUR(r.horodatage)  AS heure,
           ROUND(AVG((r.nb_velos_mecaniques + r.nb_velos_electriques)
                     / NULLIF(r.nb_velos_mecaniques + r.nb_velos_electriques + r.nb_bornes_libres, 0)), 3)
                               AS taux_remplissage_moyen,
           COUNT(*)            AS nb_releves
      FROM releve_station r
      JOIN station s ON s.id_station = r.id_station
     WHERE r.horodatage >= p_debut AND r.horodatage < p_fin
     GROUP BY s.id_station, s.nom, HOUR(r.horodatage)
     ORDER BY s.id_station, heure;
END$$

-- Recettes par formule : factures encaissées et en attente sur la période d'émission.
-- Optimisation : on part des FACTURES de la période (index idx_facture_date, plage de dates)
-- puis on remonte à l'abonnement par sa clé primaire. L'ancienne version partait de
-- formule -> abonnement et parcourait donc TOUS les abonnements, quelle que soit la période.
DROP PROCEDURE IF EXISTS sp_stat_recettes_par_formule$$
CREATE PROCEDURE sp_stat_recettes_par_formule(IN p_debut DATETIME, IN p_fin DATETIME)
BEGIN
    SELECT fo.id_formule,
           fo.libelle,
           COALESCE(x.nb_factures, 0)         AS nb_factures,
           COALESCE(x.recettes_encaissees, 0) AS recettes_encaissees,
           COALESCE(x.en_attente, 0)          AS en_attente
      FROM formule fo
      LEFT JOIN (SELECT a.id_formule,
                        COUNT(*) AS nb_factures,
                        SUM(CASE WHEN f.statut_paiement = 'payee'      THEN f.montant_total ELSE 0 END)
                                 AS recettes_encaissees,
                        SUM(CASE WHEN f.statut_paiement = 'en_attente' THEN f.montant_total ELSE 0 END)
                                 AS en_attente
                   FROM facture f
                   JOIN abonnement a ON a.id_abonnement = f.id_abonnement
                  WHERE f.date_emission >= p_debut AND f.date_emission < p_fin
                  GROUP BY a.id_formule) x
        ON x.id_formule = fo.id_formule
     ORDER BY recettes_encaissees DESC, fo.libelle;
END$$

-- Taux d'indisponibilité de la flotte : part du temps passée « en atelier » ou « défectueux »,
-- calculée à partir de HISTORIQUE_ETAT, par type de vélo et au total (ligne « tous »).
--
-- Optimisation : seules comptent les lignes de la période ET, pour chaque vélo, le
-- dernier état connu avant p_debut (l'état dans lequel il entre dans la période).
-- Ce dernier état est trouvé par une sous-requête corrélée servie par l'index
-- idx_hist_etat_velo_date (id_velo, date_heure) en parcours descendant : une seule
-- lecture d'index par vélo. L'ancienne version appliquait la fonction de fenêtre LEAD
-- à tout l'historique antérieur à p_fin (des millions de lignes pour une période de 30 jours).
DROP PROCEDURE IF EXISTS sp_stat_indisponibilite_flotte$$
CREATE PROCEDURE sp_stat_indisponibilite_flotte(IN p_debut DATETIME, IN p_fin DATETIME)
BEGIN
    WITH bornes_hist AS (
        -- changements d'état survenus pendant la période.
        -- Aucun index ne commence par date_heure : le filtre sur les 4 valeurs de l'ENUM
        -- (NOT NULL, donc sans effet sur le résultat) permet à l'optimiseur de lire
        -- idx_hist_etat_etat_date (etat_velo, date_heure) en 4 plages de dates au lieu
        -- de parcourir l'index entier (10 M d'entrées).
        SELECT h.id_hist_etat
          FROM historique_etat h
         WHERE h.etat_velo IN ('disponible', 'en_location', 'en_atelier', 'defectueux')
           AND h.date_heure >= p_debut AND h.date_heure < p_fin
        UNION ALL
        -- état de chaque vélo à l'ouverture de la période
        SELECT (SELECT h.id_hist_etat
                  FROM historique_etat h
                 WHERE h.id_velo = v.id_velo AND h.date_heure < p_debut
                 ORDER BY h.date_heure DESC, h.id_hist_etat DESC
                 LIMIT 1)
          FROM velo v
    ),
    periodes AS (
        SELECT h.id_velo,
               h.etat_velo,
               GREATEST(h.date_heure, p_debut) AS debut,
               LEAST(COALESCE(LEAD(h.date_heure) OVER (PARTITION BY h.id_velo
                                                       ORDER BY h.date_heure, h.id_hist_etat),
                              p_fin), p_fin)   AS fin
          FROM bornes_hist b
          JOIN historique_etat h ON h.id_hist_etat = b.id_hist_etat
    )
    SELECT COALESCE(v.type_velo, 'tous')       AS type_velo,
           COUNT(DISTINCT p.id_velo)           AS nb_velos,
           ROUND(100 * SUM(CASE WHEN p.etat_velo IN ('en_atelier', 'defectueux')
                                THEN TIMESTAMPDIFF(SECOND, p.debut, p.fin) ELSE 0 END)
                 / NULLIF(SUM(TIMESTAMPDIFF(SECOND, p.debut, p.fin)), 0), 2)
                                               AS taux_indisponibilite_pct
      FROM periodes p
      JOIN velo v ON v.id_velo = p.id_velo
     WHERE p.fin > p.debut
     GROUP BY v.type_velo WITH ROLLUP;
END$$

DELIMITER ;

-- =============================================================================
--  9. ÉVÉNEMENTS PLANIFIÉS
--     Désactivés tant que l'ordonnanceur est arrêté :
--         SET GLOBAL event_scheduler = ON;      (à mettre dans my.cnf pour le rendre permanent)
-- =============================================================================
DROP EVENT IF EXISTS ev_releve_stations;
CREATE EVENT ev_releve_stations
    ON SCHEDULE EVERY 15 MINUTE
    COMMENT 'Instantané du remplissage des stations'
    DO CALL sp_releve_stations();

DROP EVENT IF EXISTS ev_expirer_abonnements;
CREATE EVENT ev_expirer_abonnements
    ON SCHEDULE EVERY 1 HOUR
    COMMENT 'Renouvellement automatique et expiration des abonnements échus'
    DO CALL sp_expirer_abonnements();

DROP EVENT IF EXISTS ev_facturer_locations;
CREATE EVENT ev_facturer_locations
    ON SCHEDULE EVERY 1 DAY STARTS (TIMESTAMP(CURRENT_DATE) + INTERVAL 1 DAY + INTERVAL 2 HOUR)
    COMMENT 'Facturation nocturne des trajets hors durée gratuite'
    DO CALL sp_facturer_toutes_locations();
