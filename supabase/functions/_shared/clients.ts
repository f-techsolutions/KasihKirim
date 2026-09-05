import { createClient } from 'jsr:@supabase/supabase-js@2';

/** Caller-scoped: RLS applies. Use for anything the user is allowed to do. */
export function userClient(req: Request) {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: req.headers.get('Authorization') ?? '' } } },
  );
}

/** Bypasses RLS. Only for internal.* writes and idempotency bookkeeping.
 *  Never derive the actor from the request body when using this. */
export function adminClient() {
  return createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    { auth: { persistSession: false } },
  );
}

export async function requireUser(req: Request) {
  const { data, error } = await userClient(req).auth.getUser();
  if (error || !data.user) throw new Error('UNAUTHENTICATED');
  return data.user;
}
