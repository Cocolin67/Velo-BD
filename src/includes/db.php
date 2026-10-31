<?php
// Connexion + fonctions communes. Adaptez les 4 lignes à votre configuration.
$hote = 'localhost';
$base = 'velo_libre_service';
$user = 'root';
$mdp  = '';

try {
    $pdo = new PDO("mysql:host=$hote;dbname=$base;charset=utf8mb4", $user, $mdp, [
        PDO::ATTR_ERRMODE            => PDO::ERRMODE_EXCEPTION,
        PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC,
    ]);
} catch (PDOException $e) {
    die('<p style="color:red;font-family:sans-serif">Connexion impossible : ' . htmlspecialchars($e->getMessage()) . '</p>');
}

function e($v): string
{
    return htmlspecialchars((string) $v, ENT_QUOTES, 'UTF-8');
}

// Affiche le résultat d'une requête sous forme de tableau HTML.
function tableau(PDO $pdo, string $titre, string $sql, array $params = []): void
{
    $st = $pdo->prepare($sql);
    $st->execute($params);
    $lignes = $st->fetchAll();
    echo '<section class="carte"><h2>' . e($titre) . ' <span class="badge">' . count($lignes) . '</span></h2>';
    if (!$lignes) {
        echo '<p><em>Aucune donnée.</em></p></section>';
        return;
    }
    echo '<div class="scroll"><table><tr>';
    foreach (array_keys($lignes[0]) as $col) {
        echo '<th>' . e($col) . '</th>';
    }
    echo '</tr>';
    foreach ($lignes as $l) {
        echo '<tr>';
        foreach ($l as $v) {
            echo '<td>' . ($v === null ? '<em>NULL</em>' : e($v)) . '</td>';
        }
        echo '</tr>';
    }
    echo '</table></div></section>';
}
