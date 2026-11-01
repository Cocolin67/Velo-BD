# Vélo libre-service 🚲

Système de gestion d’un réseau de vélos en libre-service réalisé dans le cadre du projet de base de données **BD70** à l’UTBM.

Le projet modélise les stations, les bornes, la flotte de vélos mécaniques et électriques, les usagers, les abonnements, les locations, la maintenance et la régulation du réseau. Une interface PHP permet de consulter les données, d’effectuer des locations et de suivre les principaux indicateurs d’exploitation.

## Fonctionnalités

### Interface web actuellement disponible

- consultation des stations, des vélos, des locations, des historiques et des signalements
- indicateurs du réseau : nombre de stations, vélos, locations, recettes et durée moyenne
- suivi de l’occupation des stations et filtrage des vélos par type
- enregistrement d’un emprunt et d’une restitution
- calcul automatique de la durée et du coût d’une location par trigger
- création et consultation de signalements concernant un vélo ou une station.

### Base de données

- modèle relationnel normalisé avec gestion des rôles (`usager`, `operateur`,  `administrateur`)
- contraintes d’intégrité pour garantir qu’un vélo et une borne ne sont pas utilisés à plusieurs endroits simultanément
- historisation des changements d’état et de position des vélos
- procédures stockées pour les abonnements, locations, maintenance, rééquilibrage et statistiques
- triggers pour l’historisation, la validation des locations et la facturation.

La base contient également les structures nécessaires à l’authentification, à la maintenance et à la régulation. L’interface web est volontairement limitée au périmètre minimal du projet.

## Aperçu

### Cas d’utilisation

![Diagramme de cas d’utilisation](docs/diagrams/use_cases.svg)

### Modèle conceptuel

![Modèle conceptuel de données](docs/diagrams/conceptual_data_model.svg)

### Modèle logique

![Modèle logique de données](docs/diagrams/logical_data_model.svg)

## Prérequis

- **MySQL 8** ou **MariaDB**
- **PHP 8.0 ou supérieur** avec l’extension `pdo_mysql` activée
- le client MySQL en ligne de commande est facultatif.

## Installation

### 1. Créer la base de données

Exécuter les scripts SQL dans cet ordre :

1. [`database/schema.sql`](database/schema.sql) : base, tables, contraintes et index
2. [`database/triggers.sql`](database/triggers.sql) : automatisation et historisation
3. [`database/procedures.sql`](database/procedures.sql) : procédures métier et statistiques.

Avec le client MySQL :

```bash
mysql -u root -p < database/schema.sql
mysql -u root -p < database/triggers.sql
mysql -u root -p < database/procedures.sql
```

Sous PowerShell, l’équivalent est :

```powershell
Get-Content database\schema.sql -Raw | mysql -u root -p
Get-Content database\triggers.sql -Raw | mysql -u root -p
Get-Content database\procedures.sql -Raw | mysql -u root -p
```

Les scripts ne fournissent pas de jeu de données de démonstration. Ajoutez des données factices dans `velo_libre_service` avant d’utiliser l’interface.

### 2. Configurer la connexion PHP

Modifier les quatre paramètres de connexion dans [`src/includes/db.php`](src/includes/db.php) :

```php
$hote = 'localhost';
$base = 'velo_libre_service';
$user = 'root';
$mdp  = '';
```

Pour un usage réel, utilisez un compte MySQL dédié et ne conservez pas ses identifiants dans le dépôt.

### 3. Lancer l’interface

Depuis la racine du dépôt :

```bash
php -S localhost:8000 -t src
```

Puis ouvrir <http://localhost:8000>.

Les pages principales sont :

- [`index.php`](src/index.php) : tableaux de données
- [`fonctionnalites.php`](src/fonctionnalites.php) : indicateurs, locations,
  filtres et signalements.

## Organisation du dépôt

```text
database/
├── schema.sql       # Schéma relationnel et contraintes
├── triggers.sql     # Triggers d’intégrité et d’historisation
└── procedures.sql   # Procédures métier et statistiques
docs/
├── diagrams/        # Diagrammes UML, conceptuel et logique
└── instructions/   # Sujet du projet
src/
├── index.php
├── fonctionnalites.php
├── includes/        # Connexion et composants communs
└── assets/          # Feuille de style
```

## Documentation du projet

Le sujet et les livrables graphiques sont disponibles dans [`docs/`](docs/). Les commentaires présents dans les scripts SQL détaillent les choix de modélisation, les contraintes et les index.

## Licence

Ce projet est distribué sous licence [MIT](LICENSE).
