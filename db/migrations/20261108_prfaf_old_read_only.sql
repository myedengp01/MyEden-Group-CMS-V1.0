-- MyEden Group CMS V1.0 · v2026.11.08 · MEG-PRFAF moved to the CMS (Purchasing & Petty Cash).
-- The old MEG-PRFAF tables stop taking new entries from the app; reading stays allowed. (The old test data was removed on CLC's confirm, 8 Nov 2026.)
revoke insert, update on public.prfaf_submissions, public.prfaf_items, public.ledger_accounts, public.ledger_transactions from anon, authenticated;
