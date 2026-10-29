<?php /* Variable attendue : $titre */ ?>
<!DOCTYPE html>
<html lang="fr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title><?= e($titre) ?> · Vélo libre-service</title>
  <link rel="stylesheet" href="assets/style.css">
  <link rel="icon" href="favicon.ico" type="image/x-icon">
</head>
<body>
  <header class="topbar">
    <strong>🚲 Vélo libre-service</strong>
    <nav>
      <a href="index.php">Données</a>
      <a href="fonctionnalites.php">Fonctionnalités</a>
    </nav>
  </header>
  <!-- Swup remplace uniquement le contenu de #swup à chaque navigation -->
  <main id="swup" class="transition-main">
