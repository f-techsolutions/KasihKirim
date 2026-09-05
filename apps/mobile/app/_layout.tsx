import { useEffect, useState } from 'react';
import { Stack } from 'expo-router';
import { SafeAreaProvider } from 'react-native-safe-area-context';
import { QueryClient, QueryClientProvider } from '@tanstack/react-query';
import { StatusBar } from 'expo-status-bar';
import '@/core/i18n';
import { initLocalDb } from '@/core/db/schema';
import { color } from '@/ui/tokens';

const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      retry: 3,
      // Long stale time: on 3G, refetching costs the user prepaid credit.
      staleTime: 60_000,
      gcTime: 24 * 60 * 60 * 1000,
      networkMode: 'offlineFirst',
    },
    mutations: { networkMode: 'offlineFirst' },
  },
});

export default function RootLayout() {
  const [ready, setReady] = useState(false);

  useEffect(() => {
    initLocalDb();
    setReady(true);
    // Deliberately NOT awaited at startup: config, push registration and
    // analytics all run after first paint. A config outage in Beluran must
    // never look like a broken app. See ANDROID.md §4.2.
  }, []);

  if (!ready) return null;

  return (
    <QueryClientProvider client={queryClient}>
      <SafeAreaProvider>
        <StatusBar style="light" backgroundColor={color.green900} />
        <Stack screenOptions={{
          headerStyle: { backgroundColor: color.green900 },
          headerTintColor: color.cream,
          headerTitleStyle: { fontWeight: '800' },
          contentStyle: { backgroundColor: color.cream },
        }}>
          <Stack.Screen name="index" options={{ headerShown: false }} />
          <Stack.Screen name="(auth)" options={{ headerShown: false }} />
          <Stack.Screen name="(customer)" options={{ headerShown: false }} />
        </Stack>
      </SafeAreaProvider>
    </QueryClientProvider>
  );
}
