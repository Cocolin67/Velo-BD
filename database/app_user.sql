-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  Compte MySQL dédié à l'application web (principe du moindre privilège)
--
--  À exécuter avec un compte administrateur (root), APRÈS schema.sql,
--  triggers.sql et procedures.sql :
--      mysql -h 127.0.0.1 -P 3307 -u root -p < database/app_user.sql
--
--  Remplacer 'CHANGER_CE_MOT_DE_PASSE' par un mot de passe fort, puis le reporter
--  dans le fichier .env de l'application (DB_PASS). Ne jamais le committer.
--
--  Ce que l'application PEUT faire :
--    - lire toutes les tables et la vue v_stations_occupation (SELECT) ;
--    - exécuter les procédures et fonctions stockées (EXECUTE). Les procédures
--      sont en SQL SECURITY DEFINER (valeur par défaut) : elles s'exécutent avec
--      les droits de leur créateur, ce qui permet d'écrire dans location,
--      abonnement, facture, signalement... sans donner ces droits au compte web ;
--    - écrire directement uniquement là où l'interface en a besoin :
--      stations et bornes (administration), statut d'un signalement,
--      profil de l'utilisateur et rehachage de son mot de passe.
--
--  Ce qu'elle NE PEUT PAS faire : modifier le schéma (CREATE, ALTER, DROP),
--  créer ou supprimer des triggers et procédures, gérer les comptes (GRANT),
--  lire ou écrire des fichiers sur le serveur (FILE), insérer directement des
--  locations ou des abonnements en contournant les procédures.
--
--  Hôte : 'localhost' couvre le socket / pipe nommé, '127.0.0.1' les connexions
--  TCP (port 3307). Si MySQL tourne dans un conteneur Docker, la connexion
--  arrive depuis la passerelle du réseau Docker : remplacer l'hôte par celui-ci
--  (ex. '172.17.0.1') plutôt que par '%'.
-- =============================================================================

CREATE USER IF NOT EXISTS 'velo_app'@'localhost' IDENTIFIED BY 'CHANGER_CE_MOT_DE_PASSE';
CREATE USER IF NOT EXISTS 'velo_app'@'127.0.0.1' IDENTIFIED BY 'CHANGER_CE_MOT_DE_PASSE';

-- Repart d'un état connu si le script est rejoué (REVOKE ne supprime pas le compte)
REVOKE ALL PRIVILEGES, GRANT OPTION FROM 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';

-- Lecture et appel des procédures / fonctions
GRANT SELECT, EXECUTE ON velo_libre_service.* TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';

-- Administration des stations et de leurs bornes
GRANT INSERT, UPDATE, DELETE ON velo_libre_service.station TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';
GRANT INSERT, UPDATE, DELETE ON velo_libre_service.borne   TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';

-- Prise en charge d'un signalement (la clôture passe par sp_cloturer_signalement)
GRANT UPDATE (statut) ON velo_libre_service.signalement TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';

-- Profil : l'utilisateur modifie ses informations et son mot de passe (droits par colonne)
GRANT UPDATE (nom, prenom, email, mot_de_passe_hash)
      ON velo_libre_service.utilisateur TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';
GRANT UPDATE (telephone, date_naissance)
      ON velo_libre_service.usager      TO 'velo_app'@'localhost', 'velo_app'@'127.0.0.1';

-- Vérification
SHOW GRANTS FOR 'velo_app'@'127.0.0.1';
