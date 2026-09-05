import { useState } from 'react';
import { View, Text, TextInput, Pressable, StyleSheet, KeyboardAvoidingView } from 'react-native';
import { router } from 'expo-router';
import { useTranslation } from 'react-i18next';
import { supabase } from '@/core/api/supabase';
import { color, TOUCH_MIN } from '@/ui/tokens';

export default function Phone() {
  const { t } = useTranslation();
  const [phone, setPhone] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState<string | null>(null);

  // Malaysian mobile only at launch. Country allowlisting is a cost control as
  // much as a security one: SMS pumping is a direct hit on a RM12.50 margin.
  const full = '+60' + phone.replace(/\D/g, '').replace(/^0/, '');
  const valid = /^\+60[0-9]{8,10}$/.test(full);

  async function send() {
    setBusy(true); setErr(null);
    const { error } = await supabase.auth.signInWithOtp({ phone: full });
    setBusy(false);
    if (error) { setErr('Tak dapat hantar kod. Cuba lagi.'); return; }
    router.push({ pathname: '/(auth)/otp', params: { phone: full } });
  }

  return (
    <KeyboardAvoidingView behavior="padding" style={s.wrap}>
      <Text style={s.h1}>{t('auth.phone_title')}</Text>
      <Text style={s.sub}>{t('auth.phone_hint')}</Text>
      <View style={s.row}>
        <Text style={s.prefix}>+60</Text>
        <TextInput
          style={s.input}
          value={phone}
          onChangeText={setPhone}
          keyboardType="phone-pad"
          placeholder="12 345 6789"
          maxLength={11}
          autoFocus
        />
      </View>
      {err && <Text style={s.err}>{err}</Text>}
      <Pressable
        style={[s.btn, (!valid || busy) && s.btnOff]}
        disabled={!valid || busy}
        onPress={send}
      >
        <Text style={s.btnText}>{busy ? 'Menghantar…' : t('common.continue')}</Text>
      </Pressable>
    </KeyboardAvoidingView>
  );
}

const s = StyleSheet.create({
  wrap: { flex: 1, backgroundColor: color.cream, padding: 20, justifyContent: 'center' },
  h1: { fontSize: 24, fontWeight: '800', color: color.ink },
  sub: { color: color.grey, marginTop: 6, marginBottom: 20, fontSize: 13 },
  row: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  prefix: { fontSize: 18, fontWeight: '700', color: color.ink },
  input: {
    flex: 1, minHeight: TOUCH_MIN, borderWidth: 1.5, borderColor: color.line,
    borderRadius: 10, paddingHorizontal: 12, fontSize: 18, backgroundColor: color.white,
  },
  btn: {
    minHeight: TOUCH_MIN + 6, borderRadius: 11, backgroundColor: color.orange,
    alignItems: 'center', justifyContent: 'center', marginTop: 24,
  },
  btnOff: { backgroundColor: '#CFD8D2' },
  btnText: { color: '#fff', fontWeight: '800', fontSize: 16 },
  err: { color: color.red, marginTop: 10, fontSize: 13 },
});
