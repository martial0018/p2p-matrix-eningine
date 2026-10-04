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

The schema also creates `simulation_snapshots` and `simulation_events`. After sign-in, the engine restores the user's simulation state and persists changes and telemetry automatically. The chat migration creates participant-only order conversations, gives matched sellers access to their buyer's proof, adds the seller's secure payment-confirmation/share-release action, and supports private name and phone updates from My Profile. Arbiters and moderators can review submitted payment references and screenshot/video attachments across orders, subject to the review-role RLS policy; their approve/reject decisions persist through a role-checked RPC, and resolved cases leave the active review list. Re-run the chat migration after updating this project, then test with matched buyer and seller accounts.

Shares accrue profit only during their lock period. At maturity, the value is fixed; it does not increase while the owner waits to sell. Maturity only makes shares available for sale: the owner must submit a Cash-Out / Request Sale action before they are listed in the seller queue and can be matched to a buyer.

The chat migration lets signed-in users see only active seller offers. When a buyer matches an offer, the buyer-owned order and seller-owned queue entry are linked through a role-checked RPC so the order appears in the seller's account and the seller can view payment proof. Seller-confirmed releases mark the buyer order as holding and the seller queue entry as settled; database guards prevent stale browser snapshots from reverting those resolved statuses.

Each seller match is persisted as its own buyer order with a single matched amount. If a seller fills only part of a bid, the unmatched remainder stays in a separate open order. Re-run the chat migration to enable safe relinking when existing multi-seller matches are split.

## Deploy

Deploy the folder as a static site on Vercel, Netlify, or GitHub Pages after configuring `supabase-config.js`. Do not put a Supabase service-role key in the browser; only the anon key belongs in the frontend.
