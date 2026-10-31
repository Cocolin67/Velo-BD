  </main>

  <script src="https://unpkg.com/swup@4"></script>
  <script>
    if (typeof Swup !== 'undefined') {
      const swup = new Swup();   // conteneur par défaut : #swup

      // Met en surbrillance le lien du menu correspondant à la page affichée
      const majMenu = () => {
        const page = location.pathname.split('/').pop() || 'test.php';
        document.querySelectorAll('nav a').forEach(a =>
          a.classList.toggle('actif', a.getAttribute('href') === page));
      };
      majMenu();
      swup.hooks.on('page:view', majMenu);
    }
    // Si Swup n'est pas chargé (hors-ligne), le site fonctionne normalement sans transitions.
  </script>
</body>
</html>
