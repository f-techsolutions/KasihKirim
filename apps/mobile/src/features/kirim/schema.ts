import { z } from 'zod';

/** Shared with the Edge Function. One definition, validated on both sides:
 *  client-side is UX, server-side is the control. */
export const KirimDraft = z.object({
  kirim_type: z.enum(['BELI', 'HANTAR', 'PASARAN']),
  item_description: z.string().min(3).max(500),
  category_id: z.string().uuid(),
  est_weight_grams: z.number().int().min(100).max(500_000),
  // RM250 ceiling (C-03). Enforced again by a CHECK constraint.
  budget_cap_sen: z.number().int().positive().max(25_000).optional(),
  origin_node_id: z.string().uuid(),
  dest_node_id: z.string().uuid(),
  dest_address_id: z.string().uuid(),
  pickup_date: z.string().date().optional(),
  pickup_window: z.enum(['pagi', 'tengahari', 'petang', 'malam']).optional(),
  voucher_code: z.string().optional(),
}).refine(v => v.kirim_type !== 'BELI' || v.budget_cap_sen != null, {
  message: 'Kirim Beli mesti ada had bajet',
  path: ['budget_cap_sen'],
});

export type KirimDraft = z.infer<typeof KirimDraft>;

/** The client NEVER computes this. It renders what the server returned. */
export type Quote = {
  quote_id: string;
  expires_at: string;
  breakdown: Record<string, number>;
  goods_budget_sen: number;
  delivery_fee_sen: number;
  commission_sen: number;
  order_total_sen: number;
  carrier_earning_sen: number;
};
