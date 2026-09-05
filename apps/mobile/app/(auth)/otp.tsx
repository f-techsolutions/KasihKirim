import { useState } from 'react';
import { View, Text, TextInput, Pressable, StyleSheet } from 'react-native';
import { router, useLocalSearchParams } from 'expo-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '@/core/api/supabase';
import { color, TOUCH_MIN } from '@/ui/tokens';

export default function Otp() {
  const { t } = useTranslation();
  const { phone } = useLocalSearchParams<{ phone: string }>();
  const [code, setCode] = useState('');
  const [err, setErr] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function verify() {
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.verifyOtp({
      phone: phone!, token: code, type: 'sms',
    });
    setBusy(false);
    if (error) { setErr('Kod salah. Sila cuba lagi.'); return; }
    router.replace('/(customer)');
  }

  return (
    <View style={s.wrap}>
      <Text style={s.h1}>{t('auth.otp_title')}</Text>
      <Text style={s.sub}>{t('auth.otp_hint', { phone })}</Text>
      <TextInput
        style={s.otp}
        value={code}
        onChangeText={(v) => setCode(v.replace(/\D/g, ''))}
        keyboardType="number-pad"
        maxLength={6}
        autoFocus
        // Android SMS Retriever autofills with NO permission at all.
        // READ_SMS would trigger a Play restricted-permission review.
        autoComplete="sms-otp"
        textContentType="oneTimeCode"
      />
      {err && <Text style={s.err}>{err}</Text>}
      <Pressable
        style={[s.btn, (code.length < 6 || busy) && s.btnOff]}
        disabled={code.length < 6 || busy}
        onPress={verify}
      >
        <Text style={s.btnText}>{busy ? 'Menyemak…' : t('common.continue')}</Text>
      </Pressable>
    </View>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: color.cream, padding: 20, justifyContent: 'center' },
  h1: { fontSize: 24, fontWeight: '800', color: color.ink },
  sub: { color: color.grey, marginTop: 6, marginBottom: 20, fontSize: 13 },
  otp: {
    minHeight: TOUCH_MIN + 12, borderWidth: 1.5, borderColor: color.line, borderRadius: 10,
    fontSize: 30, fontWeight: '800', letterSpacing: 10, textAlign: 'center',
    backgroundColor: color.white, color: color.green900,
  },
  btn: {
    minHeight: TOUCH_MIN + 6, borderRadius: 11, backgroundColor: color.orange,
    alignItems: 'center', justifyContent: 'center', marginTop: 24,
  },
  btnOff: { backgroundColor: '#CFD8D2' },
  btnText: { color: '#fff', fontWeight: '800', fontSize: 16 },
  err: { color: color.red, marginTop: 10, fontSize: 13 },
});
