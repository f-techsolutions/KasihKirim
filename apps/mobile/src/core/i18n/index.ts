import i18n from 'i18next';
import { initReactI18next } from 'react-i18next';
import { getLocales } from 'expo-localization';

/** Bahasa Malaysia is the default, always. English is opt-in, never the
 *  fallback a rural user lands on by accident. See ANDROID.md §8. */
const ms = {
  common: { continue: 'Teruskan', back: 'Kembali', cancel: 'Batal', next: 'Seterusnya' },
  net: {
    online: 'Semua sudah dihantar',
    pending_one: '{{count}} perkara menunggu talian',
    pending_other: '{{count}} perkara menunggu talian',
    offline: 'Tiada talian — kerja awak disimpan',
    failed: '{{count}} perkara perlu perhatian',
  },
  auth: {
    phone_title: 'Nombor telefon awak',
    phone_hint: 'Kami hantar kod 6 angka melalui SMS.',
    otp_title: 'Masukkan kod',
    otp_hint: 'Kod dihantar ke {{phone}}',
    resend: 'Hantar semula',
  },
  kirim: {
    new: 'Buat Kirim Baru',
    step: 'Langkah {{n}} / 4',
    what: 'Apa yang awak nak?',
    item_label: 'Barang yang diminta',
    item_ph: 'Contoh: Udang galah saiz sederhana, 2kg, yang masih hidup kalau ada',
    item_help: 'Terangkan sedikit jelas untuk senang pembawa cari.',
    category: 'Kategori',
    weight: 'Anggar berat',
    budget: 'Had bajet',
    budget_help: 'Pembawa tak akan beli lebih dari jumlah ini. Kalau harga pasar lebih tinggi, kami akan tanya awak dulu.',
    budget_max: 'Had bajet maksimum {{max}}',
    refund_note: 'Baki bajet yang tak digunakan akan dipulangkan penuh kepada awak.',
  },
};

const en = { common: { continue: 'Continue', back: 'Back', cancel: 'Cancel', next: 'Next' } };

i18n.use(initReactI18next).init({
  resources: { ms: { translation: ms }, en: { translation: en } },
  lng: getLocales()[0]?.languageCode === 'en' ? 'en' : 'ms',
  fallbackLng: 'ms',
  interpolation: { escapeValue: false },
});

export default i18n;
export const money = (sen: number) =>
  new Intl.NumberFormat('ms-MY', { style: 'currency', currency: 'MYR' }).format(sen / 100);
