/**
 * @fileoverview Product trigger implementation for Semble n8n node
 * @description Handles polling and change detection for products in Semble practice management system
 * @author Mike Hatcher
 * @website https://progenious.com
 * @namespace N8nNodesSemble.Nodes.Triggers
 */

import {
  IPollFunctions,
  IDataObject,
  INodeExecutionData,
  NodeOperationError,
} from "n8n-workflow";

import { GET_PRODUCTS_QUERY } from "../shared/ProductQueries";
import {
  SemblePagination,
  buildPaginationConfig,
} from "../shared/PaginationHelpers";

/**
 * Configuration interface for product trigger operations
 * @interface ProductTriggerConfig
 */
interface ProductTriggerConfig {
  event: "newOnly" | "newOrUpdated";
  datePeriod: string;
  limit: number;
  maxPages?: number;
}

/**
 * Result interface for product trigger polling
 * @interface ProductTriggerResult
 */
interface ProductTriggerResult {
  data: INodeExecutionData[];
  hasNewData: boolean;
  pollTime: string;
  filteredCount: number;
  totalCount: number;
}

/**
 * Product trigger class for monitoring product changes
 * @class ProductTrigger
 * @description Provides polling functionality for product changes (create, update)
 */
export class ProductTrigger {
  /**
   * Resource configuration for product triggers
   * @static
   * @readonly
   */
  static readonly RESOURCE_CONFIG = {
    displayName: "Product",
    value: "product",
    description: "Monitor products for changes (create, update)",
    query: GET_PRODUCTS_QUERY,
    dateField: "updatedAt",
    apiResponseKey: "products",
  };

  /**
   * Calculates the start date for the date range based on the selected period
   * @static
   * @method calculateDateRangeStart
   * @param {string} period - The date period (1d, 1w, 1m, 3m, 6m, 12m, all)
   * @returns {Date} The calculated start date
   */
  static calculateDateRangeStart(period: string): Date {
    const now = new Date();

    switch (period) {
      case "all":
        return new Date("1970-01-01"); // Very old date to get all records
      case "1d":
        return new Date(now.getTime() - 1 * 24 * 60 * 60 * 1000); // 1 day
      case "1w":
        return new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000); // 7 days
      case "1m": {
        const date = new Date(now);
        date.setMonth(date.getMonth() - 1);
        return date;
      }
      case "3m": {
        const date = new Date(now);
        date.setMonth(date.getMonth() - 3);
        return date;
      }
      case "6m": {
        const date = new Date(now);
        date.setMonth(date.getMonth() - 6);
        return date;
      }
      case "12m": {
        const date = new Date(now);
        date.setMonth(date.getMonth() - 12);
        return date;
      }
      default: {
        const date = new Date(now);
        date.setMonth(date.getMonth() - 1);
        return date; // Default to 1 month
      }
    }
  }

  /**
   * Poll for product changes
   * @async
   * @method pollProducts
   * @param {IPollFunctions} context - n8n polling context
   * @param {ProductTriggerConfig} config - Product trigger configuration
   * @returns {Promise<ProductTriggerResult>} Product polling result
   * @throws {NodeOperationError} When polling fails or configuration is invalid
   */
  static async pollProducts(
    context: IPollFunctions,
    config: ProductTriggerConfig,
  ): Promise<ProductTriggerResult> {
    const { event, datePeriod, limit, maxPages } = config;

    // Get workflow static data for tracking last poll time
    const workflowStaticData = context.getWorkflowStaticData("node");
    const lastPoll = workflowStaticData.lastPoll as string;

    // Calculate date range based on the selected period
    const currentTime = new Date();
    const dateRangeStart = this.calculateDateRangeStart(datePeriod);

    // Calculate the cutoff date for filtering
    let cutoffDate: string;
    if (lastPoll) {
      cutoffDate = lastPoll;
    } else {
      // First run - use the date range start as cutoff
      cutoffDate = dateRangeStart.toISOString();
    }

    const now = new Date().toISOString();

    try {
      // Determine if unlimited records are requested
      const isUnlimited = limit === -1;

      // Use SemblePagination for safe, intelligent batching
      const baseVariables: IDataObject = {};

      // Apply server-side filtering based on event type
      if (event === "newOnly") {
        baseVariables.options = {
          createdAt: {
            start: cutoffDate,
            end: now,
          },
        };
      } else {
        // newOrUpdated
        baseVariables.options = {
          updatedAt: {
            start: cutoffDate,
            end: now,
          },
        };
      }

      // Execute pagination query
      const paginationResult = await SemblePagination.execute(context, {
        query: ProductTrigger.RESOURCE_CONFIG.query,
        baseVariables,
        dataPath: ProductTrigger.RESOURCE_CONFIG.apiResponseKey,
        pageSize: 100,
        returnAll: isUnlimited,
        maxPages: isUnlimited ? maxPages : undefined,
      });

      const allItems = paginationResult.data;
      const hasNewData = allItems.length > 0;

      // Update workflow static data with current time for next poll
      workflowStaticData.lastPoll = currentTime.toISOString();

      // Add metadata to items for better debugging and workflow usage
      const itemsWithMetadata = allItems.map((item: any) => {
        const isNew = !item.updatedAt || item.createdAt === item.updatedAt;
        const isUpdated = !isNew;

        return {
          json: {
            ...item,
            // Add trigger metadata
            __triggerMetadata: {
              resource: "product",
              event,
              pollTime: currentTime.toISOString(),
              isNew,
              isUpdated,
              productType: item.productType || "unknown",
              status: item.status || "unknown",
            },
          },
        };
      });

      return {
        data: itemsWithMetadata,
        hasNewData,
        pollTime: currentTime.toISOString(),
        filteredCount: allItems.length,
        totalCount: allItems.length,
      };
    } catch (error) {
      const errorMessage = error instanceof Error ? error.message : String(error);
      throw new NodeOperationError(
        context.getNode(),
        `Failed to poll products: ${errorMessage}`,
      );
    }
  }

  /**
   * Handle product changes with filtering and validation
   * @async
   * @method handleProductChanges
   * @param {IPollFunctions} context - n8n polling context
   * @param {any[]} products - Array of product data
   * @param {ProductTriggerConfig} config - Trigger configuration
   * @returns {Promise<INodeExecutionData[]>} Processed execution data
   */
  static async handleProductChanges(
    context: IPollFunctions,
    products: any[],
    config: ProductTriggerConfig,
  ): Promise<INodeExecutionData[]> {
    const { event } = config;

    // Filter products based on event type if needed
    let filteredProducts = products;

    if (event === "newOnly") {
      // Only include products where createdAt equals updatedAt (indicating new items)
      filteredProducts = products.filter((product) => {
        return !product.updatedAt || product.createdAt === product.updatedAt;
      });
    }

    // Transform products into execution data format
    return filteredProducts.map((product) => ({
      json: {
        ...product,
        // Add additional trigger context
        __triggerContext: {
          resource: "product",
          event,
          timestamp: new Date().toISOString(),
          productId: product.id,
          productName: product.name || "Unnamed Product",
          itemCode: product.itemCode || null,
          status: product.status || "unknown",
        },
      },
    }));
  }

  /**
   * Validate product trigger configuration
   * @static
   * @method validateConfig
   * @param {ProductTriggerConfig} config - Configuration to validate
   * @throws {NodeOperationError} When configuration is invalid
   */
  static validateConfig(config: ProductTriggerConfig): void {
    const { event, datePeriod, limit } = config;

    // Validate event type
    if (!["newOnly", "newOrUpdated"].includes(event)) {
      throw new Error(`Invalid event type: ${event}`);
    }

    // Validate date period
    const validPeriods = ["1d", "1w", "1m", "3m", "6m", "12m", "all"];
    if (!validPeriods.includes(datePeriod)) {
      throw new Error(`Invalid date period: ${datePeriod}`);
    }

    // Validate limit
    if (typeof limit !== "number" || (limit < -1 || limit === 0)) {
      throw new Error(`Invalid limit: ${limit}. Must be -1 or positive number`);
    }
  }

  /**
   * Get supported product event types
   * @static
   * @method getSupportedEvents
   * @returns {Array<{name: string, value: string, description: string}>} Array of supported events
   */
  static getSupportedEvents() {
    return [
      {
        name: "New or Updated",
        value: "newOrUpdated",
        description: "Trigger on new products or updates to existing products",
      },
      {
        name: "New Only",
        value: "newOnly",
        description: "Trigger only on newly created products",
      },
    ];
  }

  /**
   * Get product-specific filtering options
   * @static
   * @method getFilteringOptions
   * @returns {Array<{name: string, value: string, description: string}>} Array of filtering options
   */
  static getFilteringOptions() {
    return [
      {
        name: "Product Type",
        value: "productType",
        description: "Filter by product type (service, product, etc.)",
      },
      {
        name: "Status",
        value: "status",
        description: "Filter by product status (active, inactive, etc.)",
      },
      {
        name: "Bookable Only",
        value: "isBookable",
        description: "Only include bookable products/services",
      },
      {
        name: "Stock Level",
        value: "stockLevel",
        description: "Filter by current stock level",
      },
    ];
  }
}

/**
 * Export ProductTrigger for use in main trigger node
 */
export default ProductTrigger;
