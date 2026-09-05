import { View, Text, Pressable, ScrollView, StyleSheet } from 'react-native';
import { router } from 'expo-router';
import { useTranslation } from 'react-i18next';
import { useNetwork } from '@/core/net/status';
import { color, TOUCH_MIN } from '@/ui/tokens';

export default function Home() {
  const { t } = useTranslation();
  const { online, pending } = useNetwork();

  return (
    <ScrollView style={s.wrap} contentContainerStyle={{ padding: 16 }}>
      <Text style={s.h1}>Selamat pagi</Text>
      <Text style={s.sub}>Kg Kepayan Baru, Sepanggar</Text>

      {/* Sync state is always visible, always in plain Malay. A user must never
          wonder whether their work was saved. See ANDROID.md §5.5. */}
      <View style={[s.banner, !online ? s.bannerWarn : pending ? s.bannerWarn : s.bannerOk]}>
        <Text style={s.bannerText}>
          {!online ? t('net.offline')
            : pending ? t('net.pending', { count: pending })
            : t('net.online')}
        </Text>
      </View>

      <View style={s.hero}>
        <Text style={s.heroKicker}>Kirim dengan kasih</Text>
        <Text style={s.heroTitle}>Nak apa dari kampung hari ni?</Text>
        <Pressable style={s.cta} onPress={() => router.push('/(customer)/kirim-baru')}>
          <Text style={s.ctaText}>+ {t('kirim.new')}</Text>
        </Pressable>
      </View>

      <Text style={s.label}>Kirim Saya</Text>
      <View style={s.empty}>
        <Text style={s.emptyIcon}>📦</Text>
        <Text style={s.emptyText}>Belum ada kirim lagi.</Text>
      </View>
    </ScrollView>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: color.cream },
  h1: { fontSize: 24, fontWeight: '800', color: color.ink },
  sub: { color: color.grey, fontSize: 13, marginTop: 2, marginBottom: 14 },
  banner: { padding: 10, borderRadius: 10, marginBottom: 12, borderLeftWidth: 3 },
  bannerOk: { backgroundColor: color.green100, borderLeftColor: color.green600 },
  bannerWarn: { backgroundColor: '#FDF0C9', borderLeftColor: color.gold },
  bannerText: { fontSize: 12.5, color: color.ink },
  hero: { backgroundColor: color.green900, borderRadius: 14, padding: 16 },
  heroKicker: { color: color.cream, opacity: 0.75, fontSize: 12 },
  heroTitle: { color: color.cream, fontSize: 17, fontWeight: '800', marginTop: 4, marginBottom: 14 },
  cta: {
    minHeight: TOUCH_MIN, borderRadius: 11, backgroundColor: color.orange,
    alignItems: 'center', justifyContent: 'center',
  },
  ctaText: { color: '#fff', fontWeight: '800', fontSize: 15 },
  label: {
    fontSize: 10.5, fontWeight: '800', color: color.grey, letterSpacing: 0.6,
    textTransform: 'uppercase', marginTop: 20, marginBottom: 8,
  },
  empty: { alignItems: 'center', paddingVertical: 36 },
  emptyIcon: { fontSize: 36, opacity: 0.35 },
  emptyText: { color: color.grey, fontSize: 13.5, marginTop: 8 },
});
