<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;

/** Formules, tranches tarifaires, abonnements et factures d'un usager. */
final class SubscriptionRepository
{
    public function __construct(private readonly Database $db)
    {
    }

    /** Formules et leurs tranches (rang 1, 2...), regroupées par formule. */
    public function formules(): array
    {
        $formules = $this->db->fetchAll(
            'SELECT id_formule, libelle, prix, duree_validite_jours, duree_gratuite_min, supplement_electrique
               FROM formule ORDER BY prix'
        );
        $tranches = $this->db->fetchAll(
            'SELECT id_formule, rang, duree_tranche_min, tarif_tranche FROM tranche_tarifaire ORDER BY id_formule, rang'
        );

        $byFormule = [];
        foreach ($tranches as $t) {
            $byFormule[$t['id_formule']][] = $t;
        }
        foreach ($formules as &$f) {
            $f['tranches'] = $byFormule[$f['id_formule']] ?? [];
        }

        return $formules;
    }

    /** Abonnement valide à cet instant (même règle que sp_emprunter_velo). */
    public function current(int $idUsager): ?array
    {
        return $this->db->fetchOne(
            "SELECT a.id_abonnement, a.date_debut, a.date_fin, a.statut, a.renouvellement_auto,
                    f.libelle, f.duree_gratuite_min, f.supplement_electrique
               FROM abonnement a
               JOIN formule f ON f.id_formule = a.id_formule
              WHERE a.id_utilisateur = ? AND a.statut = 'actif'
                AND a.date_debut <= NOW() AND a.date_fin > NOW()
              ORDER BY a.date_fin DESC
              LIMIT 1",
            [$idUsager],
        );
    }

    public function history(int $idUsager): array
    {
        return $this->db->fetchAll(
            'SELECT a.id_abonnement, a.date_debut, a.date_fin, a.statut, a.renouvellement_auto, f.libelle, f.prix
               FROM abonnement a
               JOIN formule f ON f.id_formule = a.id_formule
              WHERE a.id_utilisateur = ?
              ORDER BY a.date_debut DESC
              LIMIT 20',
            [$idUsager],
        );
    }

    public function invoices(int $idUsager): array
    {
        return $this->db->fetchAll(
            'SELECT fa.id_facture, fa.date_emission, fa.montant_total, fa.statut_paiement, f.libelle
               FROM facture fa
               JOIN abonnement a ON a.id_abonnement = fa.id_abonnement
               JOIN formule f    ON f.id_formule    = a.id_formule
              WHERE a.id_utilisateur = ?
              ORDER BY fa.date_emission DESC
              LIMIT 10',
            [$idUsager],
        );
    }

    /** Titulaire d'un abonnement (contrôle d'accès avant toute action). */
    public function ownerOf(int $idAbonnement): ?int
    {
        $owner = $this->db->fetchValue('SELECT id_utilisateur FROM abonnement WHERE id_abonnement = ?', [$idAbonnement]);

        return $owner === null ? null : (int) $owner;
    }

    public function subscribe(int $idUsager, int $idFormule, bool $autoRenew): int
    {
        $r = $this->db->call('sp_souscrire_abonnement', [$idUsager, $idFormule, $autoRenew], ['id_abonnement', 'id_facture']);

        return (int) $r['out']['id_abonnement'];
    }

    public function renew(int $idAbonnement): void
    {
        $this->db->call('sp_renouveler_abonnement', [$idAbonnement], ['id_nouveau', 'id_facture']);
    }

    public function cancel(int $idAbonnement): void
    {
        $this->db->call('sp_resilier_abonnement', [$idAbonnement]);
    }
}
