import '../../../shared/models/entities.dart';

class CustomerAdvance {
  const CustomerAdvance({
    required this.id,
    required this.reference,
    required this.amount,
    required this.remaining,
    required this.zatcaStatus,
  });

  final int id;
  final String reference, amount, remaining, zatcaStatus;

  int get remainingMinor => ((double.tryParse(remaining) ?? 0) * 100).round();
}

class CustomerAdvancePage {
  const CustomerAdvancePage({
    required this.items,
    required this.page,
    required this.lastPage,
    required this.total,
  });
  final List<CustomerAdvance> items;
  final int page, lastPage, total;
}

class QuotationAdvanceDraft {
  const QuotationAdvanceDraft({
    required this.amount,
    required this.method,
    this.accountId,
    this.category,
    this.reasonCode,
    this.reason,
  });
  final String amount, method;
  final int? accountId;
  final String? category, reasonCode, reason;

  Map<String, Object?> toJson() => {
    'amount': amount,
    'method': method,
    if (accountId != null) 'account_id': accountId,
    if (category?.trim().isNotEmpty == true) 'category': category!.trim(),
    if (reasonCode?.trim().isNotEmpty == true)
      'reason_code': reasonCode!.trim(),
    if (reason?.trim().isNotEmpty == true) 'reason': reason!.trim(),
  };
}

class BackendSnapshot {
  const BackendSnapshot({
    required this.products,
    required this.categories,
    required this.customers,
    required this.sales,
    required this.locations,
    required this.paymentOptions,
    required this.stockItems,
    required this.business,
    required this.user,
    required this.profitLoss,
    required this.units,
    required this.taxes,
    required this.brands,
  });

  final List<Product> products;
  final List<Category> categories;
  final List<Customer> customers;
  final List<Sale> sales;
  final List<BusinessLocation> locations;
  final List<PaymentOption> paymentOptions;
  final List<StockItem> stockItems;
  final BusinessProfile business;
  final UserProfile user;
  final ProfitLoss profitLoss;
  final List<LookupOption> units, taxes;
  final List<LookupOption> brands;
}

class BackendInsights {
  const BackendInsights({
    required this.sales,
    required this.stockItems,
    required this.profitLoss,
  });

  final List<Sale> sales;
  final List<StockItem> stockItems;
  final ProfitLoss profitLoss;
}

class CreatedSale {
  const CreatedSale({
    required this.id,
    required this.invoiceNo,
    required this.invoicePdfUrl,
    required this.idempotentReplay,
    this.kitchenPrintJobsUrl,
    this.customerAdvance,
  });

  final String id, invoiceNo, invoicePdfUrl;
  final bool idempotentReplay;
  final String? kitchenPrintJobsUrl;
  final CustomerAdvance? customerAdvance;
}

abstract interface class BackendRepository {
  Future<BackendSnapshot> load(String accessToken);

  Future<BackendInsights> loadInsights(
    String accessToken,
    List<Product> products,
    List<Customer> customers,
  );

  Future<LookupOption> createUnit({
    required String accessToken,
    required String name,
    required String shortName,
    required bool allowDecimal,
  });
  Future<List<Category>> categories(String accessToken);
  Future<void> createCategory({
    required String accessToken,
    required String name,
    String nameAr,
    String? parentId,
  });
  Future<void> updateCategory({
    required String accessToken,
    required String id,
    required String name,
    String nameAr,
  });
  Future<void> deleteCategory({
    required String accessToken,
    required String id,
    String? replacementId,
  });
  Future<bool> checkSku({
    required String accessToken,
    required String sku,
    String? excludeProductId,
  });
  Future<void> deleteProduct(String accessToken, String id);
  Future<Product> updateProductStatus({
    required String accessToken,
    required Product product,
    required bool active,
  });
  Future<Product> removeProductImage({
    required String accessToken,
    required Product product,
  });

  Future<Customer> createCustomer({
    required String accessToken,
    required String name,
    required String mobile,
    String email,
    String taxNumber,
    String businessName,
    String commercialRegistrationNumber,
    String addressLine1,
    String addressLine2,
    String city,
    String state,
    String country,
    String zipCode,
    String landmark,
    String streetName,
    String buildingNumber,
    String additionalNumber,
    String customField1,
    String customField2,
    String customField3,
    String customField4,
    String contactId,
    String prefix,
    String middleName,
    String lastName,
    String alternateNumber,
    String landline,
    String dateOfBirth,
    String customerGroupId,
    String payTermNumber,
    String payTermType,
    String shippingAddress,
    String position,
  });

  Future<Customer> customerDetail({
    required String accessToken,
    required String id,
  });

  Future<Customer> updateCustomer({
    required String accessToken,
    required Customer customer,
    required String name,
    required String mobile,
    String email,
    String taxNumber,
    String businessName,
    String commercialRegistrationNumber,
    String addressLine1,
    String addressLine2,
    String city,
    String state,
    String country,
    String zipCode,
    String landmark,
    String streetName,
    String buildingNumber,
    String additionalNumber,
    String customField1,
    String customField2,
    String customField3,
    String customField4,
    String contactId,
    String prefix,
    String middleName,
    String lastName,
    String alternateNumber,
    String landline,
    String dateOfBirth,
    String customerGroupId,
    String payTermNumber,
    String payTermType,
    String shippingAddress,
    String position,
  });

  Future<CreatedSale> createSale({
    required String accessToken,
    required String locationId,
    required String cashRegisterId,
    required Customer customer,
    required List<CartLine> lines,
    required String paymentMethod,
    List<PaymentAllocation> payments = const [],
    required int total,
    required int grossDiscount,
    required String clientTransactionId,
    bool isCreditSale = false,
    bool isKitchenOrder = false,
    String? orderTaxId,
    String? serviceTypeId,
    String grossDiscountType = 'fixed',
    double grossDiscountRate = 0,
    bool isQuotation = false,
    String? quotationValidityDate,
    String? quotationTerms,
    String? quotationAttention,
    String? quotationDeliveryDate,
    String? quotationInvoiceDate,
    String? vehicleNumber,
    String? quotationAdvancePayment,
    QuotationAdvanceDraft? quotationAdvance,
    CustomerAdvance? customerAdvance,
  });

  Future<CustomerAdvancePage> customerAdvances({
    required String accessToken,
    required int contactId,
    required int locationId,
    int page = 1,
    int perPage = 100,
  });

  Future<CustomerAdvance> syncCustomerAdvance({
    required String accessToken,
    required int id,
  });

  Future<String> createSaleReturn({
    required String accessToken,
    required Sale sale,
    required Map<String, int> quantities,
  });

  Future<List<SaleReturnRecord>> saleReturns({required String accessToken});

  Future<Product> createProduct({
    required String accessToken,
    required ProductDraft draft,
    bool quick,
  });
  Future<Product> updateProduct({
    required String accessToken,
    required Product product,
    required ProductDraft draft,
  });
  Future<List<Product>> bulkUpdateProducts({
    required String accessToken,
    required List<Product> products,
    String? categoryId,
    String? locationId,
    int? sellingPrice,
  });
  Future<List<Product>> importProducts({
    required String accessToken,
    required List<int> bytes,
    required String fileName,
  });
}
