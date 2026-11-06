-- ============================================================================
--  Migration 001 : index couvrants pour les statistiques
--
--  Aligne une base EXISTANTE sur schema.sql (commit « optimisation de l'interface ») :
--    - location.idx_loc_emprunt          (date_heure_emprunt)
--        -> (date_heure_emprunt, date_heure_restitution,
--            id_borne_depart, id_borne_arrivee, duree_min, cout)
--    - releve_station.idx_releve_horodatage (horodatage)
--        -> (horodatage, id_station, nb_velos_mecaniques,
--            nb_velos_electriques, nb_bornes_libres)
--
--  Script ré-exécutable : un index n'est reconstruit que si sa définition actuelle
--  diffère de la cible (comparaison des colonnes dans information_schema.STATISTICS).
--  Sur une base de plusieurs Go, chaque reconstruction prend du temps (lecture
--  complète de la table) : ALGORITHM=INPLACE, LOCK=NONE permet de continuer à lire
--  et écrire pendant l'opération (pas de copie de table).
--
--  Usage (en root) :
--    mysql -h 127.0.0.1 -P 3307 -u root -p --default-character-set=utf8mb4 \
--          < database/migrations/001_index_couvrants_stats.sql
--  puis ré-exécuter database/procedures.sql (procédures sp_stat_* réécrites).
-- ============================================================================

USE velo_libre_service;

DELIMITER $$

DROP PROCEDURE IF EXISTS tmp_migration_index$$
CREATE PROCEDURE tmp_migration_index(IN p_table VARCHAR(64), IN p_index VARCHAR(64),
                                     IN p_colonnes VARCHAR(512))
BEGIN
    DECLARE v_actuel VARCHAR(512);

    SELECT GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX SEPARATOR ',')
      INTO v_actuel
      FROM information_schema.STATISTICS
     WHERE TABLE_SCHEMA = DATABASE() AND TABLE_NAME = p_table AND INDEX_NAME = p_index;

    IF v_actuel <=> REPLACE(p_colonnes, ' ', '') THEN
        SELECT CONCAT(p_table, '.', p_index, ' : déjà à jour') AS migration;
    ELSE
        SET @sql = CONCAT('ALTER TABLE `', p_table, '` ',
                          IF(v_actuel IS NULL, '', CONCAT('DROP INDEX `', p_index, '`, ')),
                          'ADD INDEX `', p_index, '` (', p_colonnes, '), ',
                          'ALGORITHM=INPLACE, LOCK=NONE');
        SELECT CONCAT(p_table, '.', p_index, ' : (', COALESCE(v_actuel, 'absent'),
                      ') -> (', p_colonnes, ')') AS migration;
        PREPARE stmt FROM @sql;
        EXECUTE stmt;
        DEALLOCATE PREPARE stmt;
    END IF;
END$$

DELIMITER ;

CALL tmp_migration_index('location', 'idx_loc_emprunt',
     'date_heure_emprunt,date_heure_restitution,id_borne_depart,id_borne_arrivee,duree_min,cout');

CALL tmp_migration_index('releve_station', 'idx_releve_horodatage',
     'horodatage,id_station,nb_velos_mecaniques,nb_velos_electriques,nb_bornes_libres');

DROP PROCEDURE tmp_migration_index;

-- Statistiques de l'optimiseur à jour après la reconstruction des index
ANALYZE TABLE location, releve_station;
