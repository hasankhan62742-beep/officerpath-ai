// OfficerPath AI — Admin panel configuration (EXAMPLE — placeholders only).
//
// HOW TO USE:
//   1. Copy this file to `config.js` in the same folder:
//        cp config.example.js config.js
//   2. Replace the two placeholder values below with the real ones from
//      your Supabase Dashboard -> Settings -> API:
//        SUPABASE_URL      -> Project URL, e.g. https://YOUR-PROJECT.supabase.co
//        SUPABASE_ANON_KEY -> anon / publishable key (NOT the service_role key)
//   3. NEVER put the service_role (secret) key here. It must never leave
//      the Supabase dashboard / Edge Function secrets.
//   4. NEVER commit config.js. It is listed in admin/.gitignore and must
//      only exist on the deployed host (uploaded with the folder).
window.OFFICERPATH_CONFIG = {
  SUPABASE_URL: 'https://YOUR-PROJECT.supabase.co',
  SUPABASE_ANON_KEY: 'YOUR-ANON-KEY',
};
