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

The chat migration lets signed-in users see only active seller offers. When a buyer matches an offer, the buyer-owned order and seller-owned queue entry are linked through a role-checked RPC so the order appears in the seller's account. Buyers save payment proof through an owner-checked RPC, and sellers can view it on the matched trade. Seller-confirmed releases mark the buyer order as holding and the seller queue entry as settled; database guards prevent stale browser snapshots from reverting those resolved statuses. Re-run the chat migration after updating this project.

Seller trade cards refresh shared orders and queue data every 15 seconds while the page is visible, and include a manual refresh action. The database also preserves an active `MATCHED` seller-queue link when an older browser snapshot tries to write it back as `WAITING`.

Seller queue remainders smaller than KES 0.01 are treated as floating-point dust, not as live offers; these fragments are neither persisted by matching nor displayed to buyers.

Treasury-matched buyer orders retain the matching admin's user ID for a private buyer/admin trade chat. The Admin Matching Console shows buyer payment references and uploaded proof media for treasury trades, while buyers can reply through the same chat. The chat migration grants this admin participation only on treasury-matched orders.

Each seller match is persisted as its own buyer order with a single matched amount. If a seller fills only part of a bid, the unmatched remainder stays in a separate open order. The chat migration safely relinks seller entries when legacy multi-seller matches are split, including preserving a seller release that happened before relinking. Re-run the chat migration after updating this project.

One seller cash-out request can be matched to at most two buyer orders; the limit follows its source order across residual queue entries. The first buyer may take a partial amount. The second buyer is eligible only when their remaining bid can take the entire outstanding sale amount. If that remainder is split across queue entries, all fragments are linked to the same buyer order and persisted together through `buyer_match_simulation_sale_entries`. The database serializes and validates the complete allocation, and rejects partial second-order matches or a third buyer order. Re-run the chat migration after updating this project.

## Deploy

Deploy the folder as a static site on Vercel, Netlify, or GitHub Pages after configuring `supabase-config.js`. Do not put a Supabase service-role key in the browser; only the anon key belongs in the frontend.
