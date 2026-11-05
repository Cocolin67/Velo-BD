-- =============================================================================
--  Système de gestion d'un réseau de vélos en libre-service
--  Comptes de démonstration utilisables dans l'interface web
--
--  Les comptes générés par seed.sql ont des hash factices : on ne peut pas s'y
--  connecter. Ce script ajoute trois comptes réels, un par rôle.
--  Mot de passe des trois comptes : Demo1234!   (hash bcrypt, coût 12)
--
--      admin@velo.local       administrateur (opérateur de régulation)
--      operateur@velo.local   opérateur de maintenance
--      usager@velo.local      usager (sans abonnement : à souscrire dans l'interface)
--
--  À exécuter après schema.sql, triggers.sql et procedures.sql (seed.sql facultatif) :
--      mysql -h 127.0.0.1 -P 3307 -u root -p --default-character-set=utf8mb4 < database/demo_accounts.sql
--  Script ré-exécutable : un compte déjà présent n'est pas recréé.
--  À NE PAS utiliser en production.
-- =============================================================================

USE velo_libre_service;

SET @hash = '$2y$12$FB6YDEohtnAKI0RBchd1l.rB6J2YpvqbpplL78I9WKVc/wWEt2XFK';

INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash)
SELECT 'Démo', 'Admin', 'admin@velo.local', @hash FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM utilisateur WHERE email = 'admin@velo.local');

INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash)
SELECT 'Démo', 'Opérateur', 'operateur@velo.local', @hash FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM utilisateur WHERE email = 'operateur@velo.local');

INSERT INTO utilisateur (nom, prenom, email, mot_de_passe_hash)
SELECT 'Démo', 'Usager', 'usager@velo.local', @hash FROM DUAL
 WHERE NOT EXISTS (SELECT 1 FROM utilisateur WHERE email = 'usager@velo.local');

INSERT IGNORE INTO operateur (id_utilisateur, matricule, specialite)
SELECT id_utilisateur, 'DEMO-ADM', 'regulation' FROM utilisateur WHERE email = 'admin@velo.local';

INSERT IGNORE INTO administrateur (id_utilisateur)
SELECT id_utilisateur FROM utilisateur WHERE email = 'admin@velo.local';

INSERT IGNORE INTO operateur (id_utilisateur, matricule, specialite)
SELECT id_utilisateur, 'DEMO-OPE', 'maintenance' FROM utilisateur WHERE email = 'operateur@velo.local';

INSERT IGNORE INTO usager (id_utilisateur, telephone)
SELECT id_utilisateur, '0600000000' FROM utilisateur WHERE email = 'usager@velo.local';

SELECT u.email,
       CASE WHEN a.id_utilisateur IS NOT NULL THEN 'administrateur'
            WHEN o.id_utilisateur IS NOT NULL THEN 'operateur'
            ELSE 'usager' END AS role
  FROM utilisateur u
  LEFT JOIN operateur      o ON o.id_utilisateur = u.id_utilisateur
  LEFT JOIN administrateur a ON a.id_utilisateur = u.id_utilisateur
 WHERE u.email LIKE '%@velo.local';
