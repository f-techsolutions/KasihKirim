import 'react-native-url-polyfill/auto';
import { createClient } from '@supabase/supabase-js';
import * as SecureStore from 'expo-secure-store';

// Tokens live in Android Keystore via SecureStore. Never AsyncStorage.
const KeystoreAdapter = {
  getItem: (k: string) => SecureStore.getItemAsync(k),
  setItem: (k: string, v: string) => SecureStore.setItemAsync(k, v),
  removeItem: (k: string) => SecureStore.deleteItemAsync(k),
};

export const supabase = createClient(
  process.env.EXPO_PUBLIC_SUPABASE_URL!,
  process.env.EXPO_PUBLIC_SUPABASE_ANON_KEY!,
  {
    auth: {
      storage: KeystoreAdapter,
      autoRefreshToken: true,
      persistSession: true,
      detectSessionInUrl: false,
    },
    global: { headers: { 'X-App-Version': '1.0.0' } },
  },
);

/** Roles come from the JWT claim, not a table join. See SECURITY.md 3.3. */
export type AppRole = 'customer' | 'seller' | 'carrier' | 'agent';
export async function currentRoles(): Promise<AppRole[]> {
  const { data } = await supabase.auth.getSession();
  return (data.session?.user.app_metadata?.roles ?? []) as AppRole[];
}
