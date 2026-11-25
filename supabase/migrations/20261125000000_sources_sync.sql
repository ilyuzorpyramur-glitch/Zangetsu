-- Installed sources travel with the account.
--
-- One row per account holding the whole set as produced by
-- SourcesBackup.build() (provider repos, installed providers, CloudStream /
-- Aniyomi / Mihon / LNReader / Mangayomi extensions, per-source settings).
-- `revision` is the coarse version cursor: a device applies a row whose
-- revision it has not seen yet, merges it union-only, and pushes the union
-- back with revision + 1. Columns mirror SourcesSyncRemote exactly:
-- user_key, payload, revision, updated_at.
create table if not exists public.sources_sync (
  user_key text not null primary key,
  payload text not null default '{}',
  revision bigint not null default 0,
  updated_at timestamptz not null default now()
);

alter table public.sources_sync enable row level security;
drop policy if exists sources_sync_own on public.sources_sync;
create policy sources_sync_own on public.sources_sync
  for all using (user_key = auth.uid()::text)
  with check (user_key = auth.uid()::text);
