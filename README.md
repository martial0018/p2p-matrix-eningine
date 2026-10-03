# P2P Matrix Engine

Static frontend with Supabase authentication and role-gated workspaces. Payment settlement remains simulated.

## Supabase setup

1. Create a Supabase project.
2. Open the SQL editor and run `supabase-schema.sql`.
3. Run `supabase-chat-migration.sql` to enable matched-trade chat.
4. Copy the project URL and anon key into `supabase-config.js`.
5. Create the first account through the site.
6. Promote that account to admin in Supabase SQL:

```sql
update public.profiles
set role = 'admin'
where id = 'YOUR_USER_UUID';
```

Roles are `buyer`, `seller`, `arbiter`, `moderator`, and `admin`. The browser hides other role workspaces, while Supabase row-level security protects profile data.

## Role domains

Configure the five hostnames in `supabase-config.js` and point each DNS record to the same deployment:

- `admin.matrix.example.com`
- `moderator.matrix.example.com`
- `arbiter.matrix.example.com`
- `user.matrix.example.com` for both regular buyers and sellers

The regular user hostname accepts both `buyer` and `seller` Supabase profile roles. Admin, moderator, and arbiter domains accept only their matching role. A regular user cannot sign in through a privileged domain, even if they try to call the client-side role switcher.

The schema also creates `simulation_snapshots` and `simulation_events`. After sign-in, the engine restores the user's simulation state and persists changes and telemetry automatically. The chat migration creates participant-only order conversations, gives matched sellers access to their buyer's proof, and adds the seller's secure payment-confirmation/share-release action; admins can review chats read-only. Re-run the chat migration after updating this project, then test with matched buyer and seller accounts.

## Deploy

Deploy the folder as a static site on Vercel, Netlify, or GitHub Pages after configuring `supabase-config.js`. Do not put a Supabase service-role key in the browser; only the anon key belongs in the frontend.
