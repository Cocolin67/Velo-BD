-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  Fonction de calcul du coût + triggers (historisation et règles de gestion)
--
--  À exécuter APRÈS schema.sql et AVANT procedures.sql :
--      mysql -u <utilisateur> -p --default-character-set=utf8mb4 < schema.sql
--      mysql -u <utilisateur> -p --default-character-set=utf8mb4 < triggers.sql
--      mysql -u <utilisateur> -p --default-character-set=utf8mb4 < procedures.sql
--
--  Le script est ré-exécutable (DROP ... IF EXISTS avant chaque création).
--  Les lignes DELIMITER sont des commandes du client `mysql` : si tu exécutes
--  ce fichier depuis un autre outil, il faut lui indiquer le délimiteur $$.
--
--  Contenu :
--    1. fn_calculer_cout           coût d'un trajet selon la formule de l'abonnement
--    2. trg_velo_ai / trg_velo_au  historisation des états et des positions
--    3. trg_location_bi / _bu      règles d'emprunt + calcul automatique du coût
--    4. trg_abonnement_bi          un seul abonnement actif à la fois par usager
--    5. trg_signalement_ai         un vélo signalé défectueux ne peut être emprunté
-- =============================================================================

USE velo_libre_service;

DELIMITER $$

-- -----------------------------------------------------------------------------
--  1. Calcul du coût d'un trajet
--
--  Règles (voir le sujet : durée gratuite, tarif par tranche, supplément VAE) :
--    - les `duree_gratuite_min` premières minutes sont gratuites ;
--    - au-delà, les tranches de la formule s'appliquent dans l'ordre de leur rang :
--      chaque tranche de rang inférieur au dernier est facturée une fois
--      (`tarif_tranche` pour `duree_tranche_min` minutes) ;
--      la tranche de rang le plus élevé se répète tant que le trajet continue
--      (toute tranche commencée est due) ;
--    - le supplément électrique s'ajoute à chaque trajet en vélo électrique ;
--    - la durée est arrondie à la minute inférieure (comme duree_min).
--  Exemple : gratuité 30 min, tranches (1 : 30 min = 1 €) et (2 : 30 min = 2 €),
--  trajet de 100 min -> reste 70 min -> 1 € + 2 € x CEIL(40/30) = 5 €.
-- -----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS fn_calculer_cout$$
CREATE FUNCTION fn_calculer_cout(
    p_id_abonnement INT UNSIGNED,
    p_id_velo       INT UNSIGNED,
    p_duree_min     INT
) RETURNS DECIMAL(8, 2)
READS SQL DATA
BEGIN
    DECLARE v_id_formule INT UNSIGNED;
    DECLARE v_gratuite   INT;                -- entiers SIGNÉS : évite les erreurs de soustraction non signée
    DECLARE v_supplement DECIMAL(6, 2);
    DECLARE v_type       VARCHAR(20);
    DECLARE v_max_rang   INT;
    DECLARE v_rang       INT;
    DECLARE v_duree      INT;
    DECLARE v_tarif      DECIMAL(6, 2);
    DECLARE v_reste      INT;
    DECLARE v_cout       DECIMAL(8, 2) DEFAULT 0;
    DECLARE v_fini       BOOLEAN DEFAULT FALSE;
    DECLARE c_tranches CURSOR FOR
        SELECT rang, duree_tranche_min, tarif_tranche
          FROM tranche_tarifaire
         WHERE id_formule = v_id_formule
         ORDER BY rang;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET v_fini = TRUE;

    SELECT f.id_formule, f.duree_gratuite_min, f.supplement_electrique
      INTO v_id_formule, v_gratuite, v_supplement
      FROM abonnement a
      JOIN formule f ON f.id_formule = a.id_formule
     WHERE a.id_abonnement = p_id_abonnement;

    IF v_id_formule IS NULL OR p_duree_min IS NULL THEN
        RETURN NULL;
    END IF;

    SELECT type_velo INTO v_type FROM velo WHERE id_velo = p_id_velo;

    SET v_reste = GREATEST(p_duree_min - v_gratuite, 0);

    IF v_reste > 0 THEN
        SELECT MAX(rang) INTO v_max_rang FROM tranche_tarifaire WHERE id_formule = v_id_formule;
        SET v_fini = FALSE;
        IF v_max_rang IS NOT NULL THEN
            OPEN c_tranches;
            boucle: LOOP
                FETCH c_tranches INTO v_rang, v_duree, v_tarif;
                IF v_fini THEN
                    LEAVE boucle;
                END IF;
                IF v_rang = v_max_rang THEN
                    SET v_cout  = v_cout + v_tarif * CEIL(v_reste / v_duree);
                    SET v_reste = 0;
                ELSE
                    SET v_cout  = v_cout + v_tarif;
                    SET v_reste = v_reste - v_duree;
                END IF;
                IF v_reste <= 0 THEN
                    LEAVE boucle;
                END IF;
            END LOOP;
            CLOSE c_tranches;
        END IF;
    END IF;

    IF v_type = 'electrique' THEN
        SET v_cout = v_cout + v_supplement;
    END IF;

    RETURN v_cout;
END$$

-- -----------------------------------------------------------------------------
--  2. Historisation des vélos (HISTORIQUE_ETAT et HISTORIQUE_POSITION)
--
--  Position d'un vélo : sur une borne ('borne'), en cours de location
--  ('en_location') ou hors réseau ('en_atelier' : toute autre situation sans borne).
--  Chaque changement d'état ou de position ferme la ligne de position ouverte
--  (date_heure_fin renseignée) et en ouvre une nouvelle.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_velo_ai$$
CREATE TRIGGER trg_velo_ai AFTER INSERT ON velo
FOR EACH ROW
BEGIN
    INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
    VALUES (NEW.id_velo, NOW(), NEW.etat_velo);

    INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, type_position)
    VALUES (NEW.id_velo, NEW.id_borne, NOW(),
            IF(NEW.id_borne IS NOT NULL, 'borne',
               IF(NEW.etat_velo = 'en_location', 'en_location', 'en_atelier')));
END$$

DROP TRIGGER IF EXISTS trg_velo_au$$
CREATE TRIGGER trg_velo_au AFTER UPDATE ON velo
FOR EACH ROW
BEGIN
    DECLARE v_ancienne VARCHAR(12);
    DECLARE v_nouvelle VARCHAR(12);

    IF NOT (OLD.etat_velo <=> NEW.etat_velo) THEN
        INSERT INTO historique_etat (id_velo, date_heure, etat_velo)
        VALUES (NEW.id_velo, NOW(), NEW.etat_velo);
    END IF;

    SET v_ancienne = IF(OLD.id_borne IS NOT NULL, 'borne',
                        IF(OLD.etat_velo = 'en_location', 'en_location', 'en_atelier'));
    SET v_nouvelle = IF(NEW.id_borne IS NOT NULL, 'borne',
                        IF(NEW.etat_velo = 'en_location', 'en_location', 'en_atelier'));

    IF NOT (OLD.id_borne <=> NEW.id_borne) OR v_ancienne <> v_nouvelle THEN
        UPDATE historique_position
           SET date_heure_fin = NOW()
         WHERE id_velo = NEW.id_velo
           AND date_heure_fin IS NULL;

        INSERT INTO historique_position (id_velo, id_borne, date_heure_debut, type_position)
        VALUES (NEW.id_velo, NEW.id_borne, NOW(), v_nouvelle);
    END IF;
END$$

-- -----------------------------------------------------------------------------
--  3. Locations : règles d'emprunt et calcul automatique du coût
--
--  Une location « en cours » (sans restitution) est contrôlée à l'insertion :
--  abonnement valide, un seul vélo à la fois par usager, vélo disponible.
--  Les locations déjà terminées (chargement de données historiques ou factices)
--  ne sont contrôlées que sur la validité de l'abonnement.
--  Dans les deux cas, le coût est calculé s'il n'est pas fourni.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_location_bi$$
CREATE TRIGGER trg_location_bi BEFORE INSERT ON location
FOR EACH ROW
BEGIN
    DECLARE v_usager INT UNSIGNED;
    DECLARE v_statut VARCHAR(10);
    DECLARE v_debut  DATETIME;
    DECLARE v_fin    DATETIME;
    DECLARE v_etat   VARCHAR(12);

    SELECT id_utilisateur, statut, date_debut, date_fin
      INTO v_usager, v_statut, v_debut, v_fin
      FROM abonnement
     WHERE id_abonnement = NEW.id_abonnement;

    IF v_statut IS NOT NULL
       AND (v_statut = 'resilie'
            OR NEW.date_heure_emprunt < v_debut
            OR NEW.date_heure_emprunt >= v_fin) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Abonnement non valide à la date de l''emprunt';
    END IF;

    IF NEW.date_heure_restitution IS NULL THEN
        IF v_statut IS NOT NULL AND v_statut <> 'actif' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Un abonnement actif est nécessaire pour emprunter un vélo';
        END IF;

        IF EXISTS (SELECT 1
                     FROM location l
                     JOIN abonnement a ON a.id_abonnement = l.id_abonnement
                    WHERE a.id_utilisateur = v_usager
                      AND l.date_heure_restitution IS NULL) THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Cet usager a déjà un vélo en cours de location';
        END IF;

        SELECT etat_velo INTO v_etat FROM velo WHERE id_velo = NEW.id_velo;
        IF v_etat IS NOT NULL AND v_etat <> 'disponible' THEN
            SIGNAL SQLSTATE '45000'
                SET MESSAGE_TEXT = 'Ce vélo n''est pas disponible (en location, en atelier ou défectueux)';
        END IF;
    ELSEIF NEW.cout IS NULL THEN
        SET NEW.cout = fn_calculer_cout(
            NEW.id_abonnement, NEW.id_velo,
            TIMESTAMPDIFF(MINUTE, NEW.date_heure_emprunt, NEW.date_heure_restitution));
    END IF;
END$$

-- Coût calculé automatiquement à la restitution
DROP TRIGGER IF EXISTS trg_location_bu$$
CREATE TRIGGER trg_location_bu BEFORE UPDATE ON location
FOR EACH ROW
BEGIN
    IF OLD.date_heure_restitution IS NULL
       AND NEW.date_heure_restitution IS NOT NULL
       AND NEW.cout IS NULL THEN
        SET NEW.cout = fn_calculer_cout(
            NEW.id_abonnement, NEW.id_velo,
            TIMESTAMPDIFF(MINUTE, NEW.date_heure_emprunt, NEW.date_heure_restitution));
    END IF;
END$$

-- -----------------------------------------------------------------------------
--  4. Abonnements : un seul abonnement actif à la fois par usager
--     (combiné à la règle « une location en cours par abonnement », cela garantit
--      qu'un usager n'emprunte qu'un vélo à la fois). Un renouvellement commence
--      à la fin de l'abonnement précédent : il ne chevauche pas.
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_abonnement_bi$$
CREATE TRIGGER trg_abonnement_bi BEFORE INSERT ON abonnement
FOR EACH ROW
BEGIN
    IF NEW.statut = 'actif'
       AND EXISTS (SELECT 1
                     FROM abonnement
                    WHERE id_utilisateur = NEW.id_utilisateur
                      AND statut = 'actif'
                      AND date_debut < NEW.date_fin
                      AND date_fin   > NEW.date_debut) THEN
        SIGNAL SQLSTATE '45000'
            SET MESSAGE_TEXT = 'Cet usager a déjà un abonnement actif sur cette période';
    END IF;
END$$

-- -----------------------------------------------------------------------------
--  5. Signalements : un vélo signalé défectueux ne peut plus être emprunté
--     (un vélo en location passera en « défectueux » à sa restitution,
--      voir sp_rendre_velo).
-- -----------------------------------------------------------------------------
DROP TRIGGER IF EXISTS trg_signalement_ai$$
CREATE TRIGGER trg_signalement_ai AFTER INSERT ON signalement
FOR EACH ROW
BEGIN
    IF NEW.id_velo IS NOT NULL AND NEW.statut <> 'clos' THEN
        UPDATE velo
           SET etat_velo = 'defectueux'
         WHERE id_velo = NEW.id_velo
           AND etat_velo = 'disponible';
    END IF;
END$$

DELIMITER ;
