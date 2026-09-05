import { useState } from 'react';
import { View, Text, TextInput, Pressable, ScrollView, StyleSheet, ActivityIndicator } from 'react-native';
import { router } from 'expo-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '@/core/api/supabase';
import { money } from '@/core/i18n';
import { color, TOUCH_MIN } from '@/ui/tokens';
import type { Quote } from '@/features/kirim/schema';

const MAX_BUDGET_SEN = 25_000; // RM250 ceiling (C-03). Re-checked server-side.
const CATS = [
  { slug: 'sayur', ms: 'Sayur' }, { slug: 'buah', ms: 'Buah' },
  { slug: 'hasil-laut', ms: 'Hasil Laut' }, { slug: 'kraf', ms: 'Kraf' },
  { slug: 'lain-lain', ms: 'Lain-lain' },
];

export default function KirimBaru() {
  const { t } = useTranslation();
  const [step, setStep] = useState(1);
  const [desc, setDesc] = useState('');
  const [cat, setCat] = useState('hasil-laut');
  const [grams, setGrams] = useState(2000);
  const [budgetSen, setBudgetSen] = useState(3500);
  const [quote, setQuote] = useState<Quote | null>(null);
  const [busy, setBusy] = useState(false);

  const overCap = budgetSen > MAX_BUDGET_SEN;

  /** The client sends WHAT it wants. The server decides the price. (BR-900)
   *  There are no coefficients in this bundle. */
  async function getQuote() {
    setBusy(true);
    const { data, error } = await supabase.functions.invoke('quote-kirim', {
      body: {
        kirim_type: 'BELI', category_slug: cat, est_weight_grams: grams,
        budget_cap_sen: budgetSen, payment_method: 'COD',
      },
    });
    setBusy(false);
    if (!error) { setQuote(data as Quote); setStep(4); }
  }

  return (
    <ScrollView style={s.wrap} contentContainerStyle={{ padding: 16 }}>
      <View style={s.prog}>
        {[1, 2, 3, 4].map((i) => (
          <View key={i} style={[s.progBar, i <= step && s.progOn]} />
        ))}
      </View>
      <Text style={s.stepLabel}>{t('kirim.step', { n: step })}</Text>

      {step === 1 && (
        <>
          <Text style={s.h1}>{t('kirim.what')}</Text>
          <Text style={s.label}>{t('kirim.item_label')}</Text>
          <TextInput
            style={s.area} multiline value={desc} onChangeText={setDesc}
            placeholder={t('kirim.item_ph')} placeholderTextColor={color.grey}
          />
          <Text style={s.help}>{t('kirim.item_help')}</Text>

          <Text style={s.label}>{t('kirim.category')}</Text>
          <View style={s.chips}>
            {CATS.map((c) => (
              <Pressable key={c.slug} onPress={() => setCat(c.slug)}
                style={[s.chip, cat === c.slug && s.chipOn]}>
                <Text style={[s.chipText, cat === c.slug && s.chipTextOn]}>{c.ms}</Text>
              </Pressable>
            ))}
          </View>

          <Text style={s.label}>{t('kirim.weight')}</Text>
          <View style={s.stepper}>
            <Pressable style={s.stepBtn} onPress={() => setGrams((g) => Math.max(500, g - 500))}>
              <Text style={s.stepBtnText}>−</Text>
            </Pressable>
            <Text style={s.stepVal}>{(grams / 1000).toFixed(1)} kg</Text>
            <Pressable style={s.stepBtn} onPress={() => setGrams((g) => Math.min(50000, g + 500))}>
              <Text style={s.stepBtnText}>+</Text>
            </Pressable>
          </View>

          <Text style={s.label}>{t('kirim.budget')}</Text>
          <TextInput
            style={s.input} keyboardType="decimal-pad"
            value={(budgetSen / 100).toString()}
            onChangeText={(v) => setBudgetSen(Math.round((parseFloat(v) || 0) * 100))}
          />
          <Text style={s.help}>{t('kirim.budget_help')}</Text>
          <Text style={[s.help, { fontWeight: '800' }]}>
            {t('kirim.budget_max', { max: money(MAX_BUDGET_SEN) })}
          </Text>
          {overCap && <Text style={s.err}>Melebihi had maksimum.</Text>}
        </>
      )}

      {step === 4 && quote && (
        <>
          <Text style={s.h1}>Semak dulu</Text>
          <View style={s.card}>
            <Row k="Had bajet barang" v={money(quote.goods_budget_sen)} bold />
            <Row k="Upah penghantaran" v={money(quote.delivery_fee_sen)} bold />
            <View style={s.total}>
              <Text style={s.totalK}>Jumlah</Text>
              <Text style={s.totalV}>{money(quote.order_total_sen)}</Text>
            </View>
          </View>
          <View style={s.okBanner}>
            <Text style={s.okText}>{t('kirim.refund_note')}</Text>
          </View>
        </>
      )}

      <View style={s.nav}>
        <Pressable style={[s.btn, s.btnGhost]}
          onPress={() => (step === 1 ? router.back() : setStep((n) => n - 1))}>
          <Text style={s.btnGhostText}>{t('common.back')}</Text>
        </Pressable>
        <Pressable
          style={[s.btn, s.btnMain, (overCap || busy) && s.btnOff]}
          disabled={overCap || busy}
          onPress={() => (step === 1 ? getQuote() : setStep((n) => n + 1))}
        >
          {busy ? <ActivityIndicator color="#fff" />
            : <Text style={s.btnMainText}>{t('common.continue')}</Text>}
        </Pressable>
      </View>
    </ScrollView>
  );
}

function Row({ k, v, bold }: { k: string; v: string; bold?: boolean }) {
  return (
    <View style={s.row}>
      <Text style={[s.rowK, bold && { fontWeight: '700', color: color.ink }]}>{k}</Text>
      <Text style={[s.rowV, bold && { fontWeight: '800' }]}>{v}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: color.cream },
  prog: { flexDirection: 'row', gap: 5, marginBottom: 10 },
  progBar: { flex: 1, height: 4, backgroundColor: color.line, borderRadius: 3 },
  progOn: { backgroundColor: color.orange },
  stepLabel: { color: color.grey, fontSize: 12.5, marginBottom: 14 },
  h1: { fontSize: 22, fontWeight: '800', color: color.ink, marginBottom: 4 },
  label: {
    fontSize: 10.5, fontWeight: '800', color: color.grey, letterSpacing: 0.6,
    textTransform: 'uppercase', marginTop: 16, marginBottom: 6,
  },
  help: { color: color.grey, fontSize: 12, marginTop: 6, lineHeight: 17 },
  err: { color: color.red, fontSize: 13, marginTop: 8, fontWeight: '700' },
  input: {
    minHeight: TOUCH_MIN, borderWidth: 1.5, borderColor: color.line, borderRadius: 10,
    paddingHorizontal: 12, fontSize: 16, backgroundColor: color.white, color: color.ink,
  },
  area: {
    minHeight: 80, borderWidth: 1.5, borderColor: color.line, borderRadius: 10,
    padding: 12, fontSize: 15, backgroundColor: color.white, textAlignVertical: 'top',
    color: color.ink,
  },
  chips: { flexDirection: 'row', flexWrap: 'wrap', gap: 7 },
  chip: {
    paddingHorizontal: 13, minHeight: 40, justifyContent: 'center',
    borderWidth: 1.5, borderColor: color.line, borderRadius: 20, backgroundColor: color.white,
  },
  chipOn: { backgroundColor: color.green700, borderColor: color.green700 },
  chipText: { fontSize: 13, fontWeight: '600', color: color.ink },
  chipTextOn: { color: '#fff' },
  stepper: {
    flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 14,
    backgroundColor: color.white, borderWidth: 1.5, borderColor: color.line,
    borderRadius: 11, padding: 8,
  },
  stepBtn: {
    width: TOUCH_MIN, height: TOUCH_MIN, borderRadius: TOUCH_MIN / 2,
    backgroundColor: color.green100, alignItems: 'center', justifyContent: 'center',
  },
  stepBtnText: { fontSize: 24, fontWeight: '800', color: color.green700 },
  stepVal: { fontSize: 22, fontWeight: '800', minWidth: 96, textAlign: 'center', color: color.ink },
  card: {
    backgroundColor: color.white, borderWidth: 1, borderColor: color.line,
    borderRadius: 14, padding: 13, marginTop: 12,
  },
  row: {
    flexDirection: 'row', justifyContent: 'space-between', paddingVertical: 7,
    borderBottomWidth: 1, borderBottomColor: color.line,
  },
  rowK: { color: color.grey, fontSize: 13.5 },
  rowV: { color: color.ink, fontSize: 13.5 },
  total: {
    flexDirection: 'row', justifyContent: 'space-between', paddingTop: 11,
    borderTopWidth: 2, borderTopColor: color.green900, marginTop: 4,
  },
  totalK: { fontSize: 16, fontWeight: '800', color: color.ink },
  totalV: { fontSize: 16, fontWeight: '800', color: color.green900 },
  okBanner: {
    backgroundColor: color.green100, borderLeftWidth: 3, borderLeftColor: color.green600,
    padding: 10, borderRadius: 10, marginTop: 12,
  },
  okText: { color: color.green700, fontSize: 12.5, lineHeight: 18 },
  nav: { flexDirection: 'row', gap: 10, marginTop: 22 },
  btn: {
    flex: 1, minHeight: TOUCH_MIN + 4, borderRadius: 11,
    alignItems: 'center', justifyContent: 'center',
  },
  btnMain: { backgroundColor: color.orange },
  btnMainText: { color: '#fff', fontWeight: '800', fontSize: 15 },
  btnGhost: { borderWidth: 1.5, borderColor: color.green600 },
  btnGhostText: { color: color.green700, fontWeight: '800', fontSize: 15 },
  btnOff: { backgroundColor: '#CFD8D2' },
});
