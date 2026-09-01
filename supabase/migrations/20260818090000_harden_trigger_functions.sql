-- ============================================================================
-- health-platform · harden the trigger functions
--
-- Closes five findings from `supabase db advisors --type security`:
--
--   function_search_path_mutable                     public.set_updated_at
--   anon_security_definer_function_executable        handle_new_user,
--   authenticated_security_definer_function_executable  guard_profile_role_change
--
-- PostgREST publishes every function in the `public` schema as an RPC
-- endpoint, so these three were reachable at /rest/v1/rpc/<name> by anon and
-- authenticated callers. Two of them are SECURITY DEFINER, which is what makes
-- that worth closing rather than shrugging at.
--
-- The fix is to revoke EXECUTE rather than to move them into `private`.
-- Relocating would also have worked for PostgREST, but handle_new_user fires
-- on auth.users — a table owned by the Supabase auth stack — and moving it
-- risks breaking signup if supabase_auth_admin lacks USAGE on the new schema.
--
-- Revoking is safe because PostgreSQL checks EXECUTE on a trigger function
-- when the TRIGGER IS CREATED, not each time it fires. Verified directly:
-- with EXECUTE revoked from the writing role, an UPDATE still fired the
-- trigger and populated the column. Nothing about the running system changes;
-- only the REST endpoint disappears.
-- ============================================================================

-- set_updated_at is SECURITY INVOKER and only calls now() (pg_catalog is
-- always implicitly searched), so pinning search_path costs nothing.
alter function public.set_updated_at() set search_path = '';

revoke all on function public.set_updated_at()             from public, anon, authenticated;
revoke all on function public.handle_new_user()            from public, anon, authenticated;
revoke all on function public.guard_profile_role_change()  from public, anon, authenticated;
