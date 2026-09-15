package com.ftechsolutions.kasihkirim.domain.model

/** rpc_seller_dashboard's response (0035_seller_dashboard_and_order_visibility.sql).
 *  Every count here is scoped server-side to the caller's own seller_id --
 *  this is a convenience aggregate, not a new read the client couldn't
 *  already derive from listMyProducts/listMyOrders one call at a time. */
data class SellerDashboard(
    val productCount: Int,
    val activeListings: Int,
    val lowStockCount: Int,
    val pendingOrders: Int,
    val completedOrders: Int,
)
