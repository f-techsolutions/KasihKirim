import { useEffect, useState } from 'react';
import { View, Text, ActivityIndicator, StyleSheet } from 'react-native';
import { router } from 'expo-router';
import { supabase } from '@/core/api/supabase';
import { color } from '@/ui/tokens';

export default function Splash() {
  const [msg, setMsg] = useState('Memuatkan…');

  useEffect(() => {
    (async () => {
      const { data } = await supabase.auth.getSession();
      // Renders from cache; never blocks on the network. A user opening the
      // app in a dead spot sees their deliveries, not a spinner.
      router.replace(data.session ? '/(customer)' : '/(auth)/phone');
    })().catch(() => setMsg('Tiada talian — cuba lagi'));
  }, []);

  return (
    <View style={s.wrap}>
      <Text style={s.brand}>Kasih<Text style={{ color: color.gold }}>Kirim</Text></Text>
      <Text style={s.tag}>Kirim dengan kasih, dari kampung ke bandar.</Text>
      <ActivityIndicator color={color.gold} style={{ marginTop: 24 }} />
      <Text style={s.msg}>{msg}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: color.green900, alignItems: 'center', justifyContent: 'center', padding: 24 },
  brand: { fontSize: 34, fontWeight: '800', color: color.cream, letterSpacing: -1 },
  tag: { color: color.cream, opacity: 0.8, marginTop: 8, textAlign: 'center', fontSize: 14 },
  msg: { color: color.cream, opacity: 0.6, marginTop: 12, fontSize: 12 },
});
