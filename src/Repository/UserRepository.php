<?php

declare(strict_types=1);

namespace App\Repository;

use App\Database\Database;

/** Requêtes sur UTILISATEUR et ses rôles (USAGER, OPERATEUR, ADMINISTRATEUR). */
final class UserRepository
{
    public function __construct(private readonly Database $db)
    {
    }

    /** Hash et rôle d'un compte (procédure sp_authentifier), null si l'email est inconnu. */
    public function findForLogin(string $email): ?array
    {
        return $this->db->call('sp_authentifier', [$email])['rows'][0][0] ?? null;
    }

    /** Inscription d'un usager (sp_inscrire_usager, transactionnelle). Renvoie son identifiant. */
    public function registerUsager(string $nom, string $prenom, string $email, string $hash, ?string $naissance, ?string $telephone): int
    {
        $result = $this->db->call(
            'sp_inscrire_usager',
            [$nom, $prenom, $email, $hash, $naissance, $telephone],
            ['id_utilisateur'],
        );

        return (int) $result['out']['id_utilisateur'];
    }

    public function updatePasswordHash(int $id, string $hash): void
    {
        $this->db->execute('UPDATE utilisateur SET mot_de_passe_hash = ? WHERE id_utilisateur = ?', [$hash, $id]);
    }

    public function findProfile(int $id): ?array
    {
        return $this->db->fetchOne(
            'SELECT u.id_utilisateur, u.nom, u.prenom, u.email, u.date_inscription, u.mot_de_passe_hash,
                    us.telephone, us.date_naissance, o.matricule, o.specialite
               FROM utilisateur u
               LEFT JOIN usager    us ON us.id_utilisateur = u.id_utilisateur
               LEFT JOIN operateur o  ON o.id_utilisateur  = u.id_utilisateur
              WHERE u.id_utilisateur = ?',
            [$id],
        );
    }

    /** Mise à jour du profil (utilisateur + usager) dans une même transaction. */
    public function updateProfile(int $id, string $nom, string $prenom, string $email, bool $isUsager, ?string $telephone, ?string $naissance): void
    {
        $this->db->transaction(function (Database $db) use ($id, $nom, $prenom, $email, $isUsager, $telephone, $naissance): void {
            $db->execute(
                'UPDATE utilisateur SET nom = ?, prenom = ?, email = ? WHERE id_utilisateur = ?',
                [$nom, $prenom, $email, $id],
            );
            if ($isUsager) {
                $db->execute(
                    'UPDATE usager SET telephone = ?, date_naissance = ? WHERE id_utilisateur = ?',
                    [$telephone, $naissance, $id],
                );
            }
        });
    }
}
