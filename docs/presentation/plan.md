# Plan de la soutenance — Vélos en libre-service (BD70)

Durée visée : 20 à 25 minutes, 22 diapositives (notes d'oral dans chaque diapositive du PPT).

Ton plan a été gardé, avec deux parties ajoutées là où ta numérotation sautait (5 et 6) :
le jeu de données factices et l'application web, qui sont des livrables du sujet.

| # | Partie | Diapositives | Message principal |
|---|--------|--------------|-------------------|
| – | Ouverture | 1. Titre · 2. Sommaire | |
| 1 | Introduction | 3. Le sujet et ses deux exigences · 4. Couverture du cahier des charges | Tout le cahier des charges est couvert, en base et en grande partie dans l'interface |
| 2 | Analyse des besoins | 5. Acteurs et cas d'utilisation · 6. Règles métier | Six règles métier, toutes garanties par la base |
| 3 | Conception de la base | 7. Modèle entité-association · 8. Modèle relationnel (20 tables) · 9. 3NF et contraintes | Un schéma en 3NF, avec quelques dénormalisations contrôlées et justifiées |
| 4 | Implémentation SQL | 10. Déclencheurs et historisation · 11. Emprunt et restitution · 12. Coût et événements planifiés | L'application n'écrit pas directement : procédures, déclencheurs, transactions |
| 5 | Jeu de données factices | 13. 5 millions de locations réalistes | Un générateur intégré à la base, avec heures de pointe, saisonnalité, attraction du centre |
| 6 | Application web | 14. Architecture Slim 4, rôles et sécurité | Le contrôleur n'a aucune requête SQL ; la base renvoie les erreurs métier |
| 7 | Évolution du projet | 15. Chronologie · 16. Problèmes rencontrés et solutions | |
| 8 | Analyse des performances | 17. Constat initial · 18. Configuration du serveur · 19. Réécriture des requêtes · 20. Résultats | D'une page bloquée (> 2 min) à des statistiques en moins de 2 s sur 30 jours |
| 9 | Conclusion | 21. Bilan, limites, perspectives · 22. Merci / questions | |

## Suggestion de répartition à l'oral

- Colin : introduction, application web (parties 1 et 6)
- Alban : analyse des besoins, conception, évolution (parties 2, 3 et 7)
- Antoine : implémentation SQL, données, performances (parties 4, 5 et 8)
- Conclusion à trois
