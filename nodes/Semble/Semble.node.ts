/**
 * @fileoverview Main Semble node implementation for n8n (Action/Trigger-based architecture)
 * @description This module provides CRUD operations for Semble practice management system using action-based structure
 * @author Mike Hatcher
 * @website https://progenious.com
 * @namespace N8nNodesSemble.Nodes
 */

import type {
  IExecuteFunctions,
  IDataObject,
  ILoadOptionsFunctions,
  INodeExecutionData,
  INodePropertyOptions,
  INodeType,
  INodeTypeDescription,
} from "n8n-workflow";

import {
  NodeApiError,
  NodeOperationError,
  NodeConnectionTypes,
} from "n8n-workflow";

import { sembleApiRequest } from "./GenericFunctions";
import {
  SemblePagination,
  buildPaginationConfig,
} from "./shared/PaginationHelpers";
import {
  GET_PATIENT_QUERY,
  GET_PATIENTS_QUERY,
  CREATE_PATIENT_MUTATION,
  UPDATE_PATIENT_MUTATION,
  DELETE_PATIENT_MUTATION,
} from "./shared/PatientQueries";

// Resource Classes - Action Hooks
import { ProductResource } from "./resources/ProductResource";
import { BookingResource } from "./resources/BookingResource";

// Field Descriptions
import {
  BOOKING_FIELDS,
  JOURNEY_STAGE_FIELD,
  CUSTOM_DATE_FIELD,
  JOURNEY_DATE_FIELD,
  JOURNEY_BOOKING_ID_FIELD,
} from "./descriptions/BookingDescription";

// Core Components - Dependency Injection & Event System
import {
  ServiceContainer,
  EventSystem,
  SchemaRegistry,
  MiddlewarePipeline,
  ServiceLifetime,
  type IServiceContainer,
  type IEventSystem,
  type ISchemaRegistry,
  type NodeExecutedEvent,
} from "../../core";

// Application Services
import { CredentialService } from "../../services/CredentialService";
import { CacheService } from "../../services/CacheService";
import { SembleQueryService } from "../../services/SembleQueryService";
import { ValidationService } from "../../services/ValidationService";

// Configuration types
import { CacheConfig } from "../../types/ConfigTypes";
import { SembleQueryConfig } from "../../services/SembleQueryService";

/**
 * Main Semble node implementation for n8n integration
 *
 * Provides comprehensive CRUD operations for the Semble practice management system
 * using a resource-based architecture. Supports patients, bookings, appointments,
 * products, and other Semble entities with built-in caching, error handling,
 * and pagination.
 *
 * Features:
 * - Multi-resource support (Patients, Bookings, Products, Appointments)
 * - Advanced field discovery and dynamic form generation
 * - Intelligent caching with TTL and auto-refresh
 * - Comprehensive error handling and retry logic
 * - Paginated data retrieval with auto-pagination options
 * - Event-driven architecture for extensibility
 *
 * @example
 * ```typescript
 * // Node configuration in n8n workflow
 * {
 *   "node": "n8n-nodes-semble.semble",
 *   "operation": "getAll",
 *   "resource": "patient",
 *   "returnAll": true,
 *   "additionalFields": {
 *     "firstName": "John"
 *   }
 * }
 * ```
 *
 * @class Semble
 * @implements {INodeType}
 * @since 2.0.0
 * @description Action/trigger-based node architecture for Semble API access
 */
export class Semble implements INodeType {
  /**
   * Static service container for dependency injection
   * @private
   */
  private static serviceContainer: IServiceContainer;

  /**
   * Initialize static service container
   * @private
   */
  private static initializeServices(): void {
    if (this.serviceContainer) return; // Already initialized

    this.serviceContainer = new ServiceContainer();

    // Default configurations
    const cacheConfig: CacheConfig = {
      enabled: true,
      defaultTtl: 24 * 60 * 60, // 24 hours in seconds
      maxSize: 1000,
      autoRefreshInterval: 60 * 60, // 1 hour in seconds
      backgroundRefresh: true,
      keyPrefix: "semble_",
    };

    const queryConfig: SembleQueryConfig = {
      name: "query",
      enabled: true,
      initTimeout: 5000,
      options: {},
      baseUrl: "https://open.semble.io/graphql", // Official Semble endpoint, can be overridden by credentials
      timeout: 30000,
      retries: {
        maxAttempts: 3,
        initialDelay: 1000,
      },
      rateLimit: {
        maxRequests: 100,
        windowMs: 60000, // 1 minute
      },
    };

    // Register core services
    this.serviceContainer.register(
      "eventSystem",
      () => new EventSystem(),
      ServiceLifetime.SINGLETON,
    );
    this.serviceContainer.register(
      "schemaRegistry",
      () => new SchemaRegistry(),
      ServiceLifetime.SINGLETON,
    );
    this.serviceContainer.register(
      "credentialService",
      () => new CredentialService(),
      ServiceLifetime.SINGLETON,
    );
    this.serviceContainer.register(
      "cacheService",
      () => new CacheService(cacheConfig),
      ServiceLifetime.SINGLETON,
    );
    this.serviceContainer.register(
      "validationService",
      () => ValidationService.getInstance(),
      ServiceLifetime.SINGLETON,
    );

    // Register middleware pipeline with event system dependency
    this.serviceContainer.register(
      "middlewarePipeline",
      (container) => {
        const eventSystem = container.resolve("eventSystem") as EventSystem;
        return new MiddlewarePipeline(eventSystem);
      },
      ServiceLifetime.SINGLETON,
    );

    // Register query service with dependencies
    this.serviceContainer.register(
      "queryService",
      (container) => {
        return new SembleQueryService(queryConfig);
      },
      ServiceLifetime.SINGLETON,
    );
  }

  /**
   * Get event system for emitting events
   * @static
   */
  private static getEventSystem(): EventSystem {
    this.initializeServices();
    return this.serviceContainer.resolve("eventSystem") as EventSystem;
  }

  /**
   * Get validation service for input validation
   * @static
   */
  private static getValidationService(): ValidationService {
    this.initializeServices();
    return this.serviceContainer.resolve(
      "validationService",
    ) as ValidationService;
  }

  /**
   * Node type description and configuration
   * @type {INodeTypeDescription}
   * @description Defines the node's appearance, properties, and available actions
   */
  description: INodeTypeDescription = {
    displayName: "Semble",
    name: "semble",
    icon: "file:semble.svg",
    group: ["input"],
    version: 1,
    subtitle: '={{$parameter["action"]}}',
    description: "Interact with Semble practice management system",
    defaults: {
      name: "Semble",
    },
    inputs: [NodeConnectionTypes.Main],
    outputs: [NodeConnectionTypes.Main],
    credentials: [
      {
        name: "sembleApi",
        required: true,
      },
    ],
    properties: [
      {
        displayName: "Action",
        name: "action",
        type: "options",
        noDataExpression: true,
        options: [
          {
            name: "Create",
            value: "create",
            description: "Create new records in Semble",
            action: "Create new records in semble",
          },
          {
            name: "Delete",
            value: "delete",
            description: "Delete records from Semble",
            action: "Delete records from semble",
          },
          {
            name: "Get",
            value: "get",
            description: "Retrieve a single record from Semble",
            action: "Get a single record from semble",
          },
          {
            name: "Get Many",
            value: "getMany",
            description: "Retrieve multiple records from Semble",
            action: "Get multiple records from semble",
          },
          {
            name: "Update",
            value: "update",
            description: "Update existing records in Semble",
            action: "Update existing records in semble",
          },
          {
            name: "Update Journey",
            value: "updateJourney",
            description: "Update booking journey stage (booking only)",
            action: "Update booking journey stage",
          },
        ],
        default: "get",
        description: "The action you want to perform",
      },
      // Resource selection
      {
        displayName: "Resource",
        name: "resource",
        type: "options",
        noDataExpression: true,
        options: [
          {
            name: "Patient",
            value: "patient",
            description: "Patient management operations",
          },
          {
            name: "Booking",
            value: "booking",
            description: "Booking management operations",
          },
          {
            name: "Product",
            value: "product",
            description:
              "Product management operations (create, read, update, delete)",
          },
        ],
        default: "patient",
        description: "The resource you want to work with",
      },
      // Patient ID for get and delete operations
      {
        displayName: "Patient ID",
        name: "patientId",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["get", "delete", "update"],
            resource: ["patient"],
          },
        },
        default: "",
        placeholder: "e.g., 68740bc493985f7d03d4f8c9",
        description: "The ID of the patient to retrieve or delete",
      },
      // Product ID for get, delete and update operations
      {
        displayName: "Product ID",
        name: "productId",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["get", "delete", "update"],
            resource: ["product"],
          },
        },
        default: "",
        placeholder: "e.g., 62e2b7d228ec4b0013179e67",
        description: "The ID of the product to retrieve, update or delete",
      },
      // Patient creation fields
      {
        displayName: "First Name",
        name: "firstName",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: "",
        description: "Patient's first name",
      },
      {
        displayName: "Last Name",
        name: "lastName",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: "",
        description: "Patient's last name",
      },
      {
        displayName: "Additional Fields",
        name: "additionalFields",
        type: "collection",
        placeholder: "Add Field",
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Address",
            name: "address",
            type: "string",
            default: "",
            description: "Patient's street address",
          },
          {
            displayName: "Birth Name",
            name: "birthName",
            type: "string",
            default: "",
            description:
              "The birth name of the patient (France INS certified practices only)",
          },
          {
            displayName: "Birth Names",
            name: "birthNames",
            type: "string",
            default: "",
            description:
              "The birth names of the patient (France INS certified practices only)",
          },
          {
            displayName: "Birth Surname",
            name: "birthSurname",
            type: "string",
            default: "",
            description: "Patient's birth surname",
          },
          {
            displayName: "City",
            name: "city",
            type: "string",
            default: "",
            description: "Patient's city",
          },
          {
            displayName: "Comments",
            name: "comments",
            type: "string",
            default: "",
            description: "Additional comments about the patient",
          },
          {
            displayName: "Country",
            name: "country",
            type: "string",
            default: "",
            description: "Patient's country (US, GB, FR, etc.)",
          },
          {
            displayName: "Date of Birth",
            name: "dob",
            type: "dateTime",
            default: "",
            description: "Patient's date of birth",
          },
          {
            displayName: "Email",
            name: "email",
            type: "string",
            placeholder: "name@email.com",
            default: "",
            description: "Patient's email address",
          },
          {
            displayName: "Gender",
            name: "gender",
            type: "string",
            default: "",
            description: "Patient's gender (male, female, etc.)",
          },
          {
            displayName: "Payment Reference",
            name: "paymentReference",
            type: "string",
            default: "",
            description: "Patient's payment reference",
          },
          {
            displayName: "Phone Number",
            name: "phoneNumber",
            type: "string",
            default: "",
            description: "Patient's phone number",
          },
          {
            displayName: "Phone Type",
            name: "phoneType",
            type: "options",
            options: [
              {
                name: "Fax",
                value: "Fax",
              },
              {
                name: "Home",
                value: "Home",
              },
              {
                name: "Mobile",
                value: "Mobile",
              },
              {
                name: "Office",
                value: "Office",
              },
              {
                name: "Other",
                value: "Other",
              },
            ],
            default: "Mobile",
            description: "Type of phone number",
          },
          {
            displayName: "Postcode",
            name: "postcode",
            type: "string",
            default: "",
            description: "Patient's postal code",
          },
          {
            displayName: "Sex",
            name: "sex",
            type: "string",
            default: "",
            description: "Patient's biological sex (male, female, etc.)",
          },
          {
            displayName: "Social Security Number",
            name: "socialSecurityNumber",
            type: "string",
            default: "",
            description:
              "Patient's social security number (13-15 characters, France only) - may require special permissions",
          },
          {
            displayName: "Title",
            name: "title",
            type: "string",
            default: "",
            description: "Patient's title (Mr, Mrs, Dr, etc.)",
          },
        ],
      },
      {
        displayName: "Place of Birth",
        name: "placeOfBirth",
        type: "collection",
        placeholder: "Add Place of Birth",
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Name",
            name: "name",
            type: "string",
            default: "",
            description: "Name of the place of birth",
          },
          {
            displayName: "Code",
            name: "code",
            type: "string",
            default: "",
            description:
              "The code for the place of birth (INSEE Code for France practices)",
          },
        ],
      },
      {
        displayName: "Communication Preferences",
        name: "communicationPreferences",
        type: "collection",
        placeholder: "Add Communication Preferences",
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Payment Reminders",
            name: "paymentReminders",
            type: "boolean",
            default: true,
            description:
              "Whether the patient wants to receive payment reminders",
          },
          {
            displayName: "Privacy Policy",
            name: "privacyPolicy",
            type: "string",
            default: "",
            description:
              "Patient's privacy policy response (accepted, declined, etc.)",
          },
          {
            displayName: "Promotional Marketing",
            name: "promotionalMarketing",
            type: "boolean",
            default: false,
            description:
              "Whether the patient wants to receive promotional marketing",
          },
          {
            displayName: "Receive Email",
            name: "receiveEmail",
            type: "boolean",
            default: true,
            description: "Whether the patient wants to receive emails",
          },
          {
            displayName: "Receive SMS",
            name: "receiveSMS",
            type: "boolean",
            default: true,
            description: "Whether the patient wants to receive SMS messages",
          },
        ],
      },
      {
        displayName: "Custom Attributes",
        name: "customAttributes",
        type: "fixedCollection",
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["patient"],
          },
        },
        default: {},
        placeholder: "Add Custom Attribute",
        typeOptions: {
          multipleValues: true,
        },
        options: [
          {
            displayName: "Custom Attribute",
            name: "customAttribute",
            values: [
              {
                displayName: "Title",
                name: "title",
                type: "string",
                required: true,
                default: "",
                description: "The title of the custom attribute",
              },
              {
                displayName: "Text",
                name: "text",
                type: "string",
                required: true,
                default: "",
                description: "The text/description of the custom attribute",
              },
              {
                displayName: "Response",
                name: "response",
                type: "string",
                required: true,
                default: "",
                description: "The response value for the custom attribute",
              },
            ],
          },
        ],
      },
      // Product creation fields
      {
        displayName: "Product Name",
        name: "name",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["product"],
          },
        },
        default: "",
        description: "Product name (required)",
      },
      {
        displayName: "Additional Fields",
        name: "additionalFields",
        type: "collection",
        placeholder: "Add Field",
        displayOptions: {
          show: {
            action: ["create"],
            resource: ["product"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Color",
            name: "color",
            type: "color",
            default: "#000000",
            description: "Product color for UI display",
          },
          {
            displayName: "Comments",
            name: "comments",
            type: "string",
            default: "",
            description: "Additional comments about the product",
          },
          {
            displayName: "Cost",
            name: "cost",
            type: "number",
            default: 0,
            description: "Product cost",
          },
          {
            displayName: "Duration",
            name: "duration",
            type: "number",
            default: 0,
            description: "Duration in minutes (for bookable products)",
          },
          {
            displayName: "Is Bookable",
            name: "isBookable",
            type: "boolean",
            default: false,
            description: "Whether this product can be booked",
          },
          {
            displayName: "Is Video Consultation",
            name: "isVideoConsultation",
            type: "boolean",
            default: false,
            description: "Whether this is a video consultation product",
          },
          {
            displayName: "Item Code",
            name: "itemCode",
            type: "string",
            default: "",
            description: "Product item code or SKU",
          },
          {
            displayName: "Price",
            name: "price",
            type: "number",
            default: 0,
            description: "Product price",
          },
          {
            displayName: "Product Type",
            name: "productType",
            type: "options",
            options: [
              {
                name: "Service",
                value: "service",
              },
              {
                name: "Product",
                value: "product",
              },
              {
                name: "Other",
                value: "other",
              },
            ],
            default: "service",
            description: "Type of product",
          },
          {
            displayName: "Requires Confirmation",
            name: "requiresConfirmation",
            type: "boolean",
            default: false,
            description: "Whether booking confirmation is required",
          },
          {
            displayName: "Requires Payment",
            name: "requiresPayment",
            type: "boolean",
            default: true,
            description: "Whether payment is required for this product",
          },
          {
            displayName: "Serial Number",
            name: "serialNumber",
            type: "string",
            default: "",
            description: "Product serial number",
          },
          {
            displayName: "Status",
            name: "status",
            type: "options",
            options: [
              {
                name: "Active",
                value: "active",
              },
              {
                name: "Inactive",
                value: "inactive",
              },
            ],
            default: "active",
            description: "Product status",
          },
          {
            displayName: "Stock Level",
            name: "stockLevel",
            type: "number",
            default: 0,
            description: "Current stock level",
          },
          {
            displayName: "Supplier Display Name",
            name: "supplierDisplayName",
            type: "string",
            default: "",
            description: "Display name for the supplier",
          },
          {
            displayName: "Supplier Name",
            name: "supplierName",
            type: "string",
            default: "",
            description: "Name of the supplier",
          },
          {
            displayName: "Tax Information",
            name: "tax",
            type: "collection",
            default: {},
            description: "Tax information for the product",
            options: [
              {
                displayName: "Tax Code",
                name: "taxCode",
                type: "string",
                default: "NONE",
                description: "Tax code identifier",
              },
              {
                displayName: "Tax Name",
                name: "taxName",
                type: "string",
                default: "No VAT",
                description: "Name of the tax",
              },
              {
                displayName: "Tax Rate",
                name: "taxRate",
                type: "number",
                default: 0,
                description: "Tax rate percentage",
              },
            ],
          },
        ],
      },
      // Product update fields
      {
        displayName: "Product ID",
        name: "productId",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["product"],
          },
        },
        default: "",
        placeholder: "e.g., 62e2b7d228ec4b0013179e67",
        description: "ID of the product to update",
      },
      {
        displayName: "Update Fields",
        name: "updateFields",
        type: "collection",
        placeholder: "Add Field",
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["product"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Comments",
            name: "comments",
            type: "string",
            default: "",
            description: "Additional comments about the product",
          },
          {
            displayName: "Cost",
            name: "cost",
            type: "number",
            default: 0,
            description: "Product cost",
          },
          {
            displayName: "Item Code",
            name: "itemCode",
            type: "string",
            default: "",
            description: "Product item code or SKU",
          },
          {
            displayName: "Price",
            name: "price",
            type: "number",
            default: 0,
            description: "Product price",
          },
          {
            displayName: "Product Name",
            name: "name",
            type: "string",
            default: "",
          },
          {
            displayName: "Product Type",
            name: "productType",
            type: "options",
            options: [
              {
                name: "Service",
                value: "service",
              },
              {
                name: "Product",
                value: "product",
              },
              {
                name: "Other",
                value: "other",
              },
            ],
            default: "service",
            description: "Type of product",
          },
          {
            displayName: "Status",
            name: "status",
            type: "options",
            options: [
              {
                name: "Active",
                value: "active",
              },
              {
                name: "Inactive",
                value: "inactive",
              },
            ],
            default: "active",
            description: "Product status",
          },
          {
            displayName: "Stock Level",
            name: "stockLevel",
            type: "number",
            default: 0,
            description: "Current stock level",
          },
          {
            displayName: "Supplier Name",
            name: "supplierName",
            type: "string",
            default: "",
            description: "Name of the supplier",
          },
          {
            displayName: "Tax Information",
            name: "tax",
            type: "collection",
            default: {},
            description: "Tax information for the product",
            options: [
              {
                displayName: "Tax Code",
                name: "taxCode",
                type: "string",
                default: "NONE",
                description: "Tax code identifier",
              },
              {
                displayName: "Tax Name",
                name: "taxName",
                type: "string",
                default: "No VAT",
                description: "Name of the tax",
              },
              {
                displayName: "Tax Rate",
                name: "taxRate",
                type: "number",
                default: 0,
                description: "Tax rate percentage",
              },
            ],
          },
        ],
      },
      // Patient update fields
      {
        displayName: "Patient ID",
        name: "patientId",
        type: "string",
        required: true,
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["patient"],
          },
        },
        default: "",
        description: "ID of the patient to update",
      },
      {
        displayName: "Update Fields",
        name: "updateFields",
        type: "collection",
        placeholder: "Add Field",
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Address",
            name: "address",
            type: "string",
            default: "",
            description: "Patient's street address",
          },
          {
            displayName: "Birth Name",
            name: "birthName",
            type: "string",
            default: "",
            description:
              "The birth name of the patient (France INS certified practices only)",
          },
          {
            displayName: "Birth Names",
            name: "birthNames",
            type: "string",
            default: "",
            description:
              "The birth names of the patient (France INS certified practices only)",
          },
          {
            displayName: "Birth Surname",
            name: "birthSurname",
            type: "string",
            default: "",
            description: "Patient's birth surname",
          },
          {
            displayName: "City",
            name: "city",
            type: "string",
            default: "",
            description: "Patient's city",
          },
          {
            displayName: "Comments",
            name: "comments",
            type: "string",
            default: "",
            description: "Additional comments about the patient",
          },
          {
            displayName: "Country",
            name: "country",
            type: "string",
            default: "",
            description: "Patient's country (US, GB, FR, etc.)",
          },
          {
            displayName: "Date of Birth",
            name: "dob",
            type: "dateTime",
            default: "",
            description: "Patient's date of birth",
          },
          {
            displayName: "Email",
            name: "email",
            type: "string",
            placeholder: "name@email.com",
            default: "",
            description: "Patient's email address",
          },
          {
            displayName: "First Name",
            name: "firstName",
            type: "string",
            default: "",
            description: "Patient's first name",
          },
          {
            displayName: "Gender",
            name: "gender",
            type: "string",
            default: "",
            description: "Patient's gender (male, female, etc.)",
          },
          {
            displayName: "Last Name",
            name: "lastName",
            type: "string",
            default: "",
            description: "Patient's last name",
          },
          {
            displayName: "Payment Reference",
            name: "paymentReference",
            type: "string",
            default: "",
            description: "Patient's payment reference",
          },
          {
            displayName: "Phone Number",
            name: "phoneNumber",
            type: "string",
            default: "",
            description: "Patient's phone number",
          },
          {
            displayName: "Phone Type",
            name: "phoneType",
            type: "options",
            options: [
              {
                name: "Fax",
                value: "Fax",
              },
              {
                name: "Home",
                value: "Home",
              },
              {
                name: "Mobile",
                value: "Mobile",
              },
              {
                name: "Office",
                value: "Office",
              },
              {
                name: "Other",
                value: "Other",
              },
            ],
            default: "Mobile",
            description: "Type of phone number",
          },
          {
            displayName: "Postcode",
            name: "postcode",
            type: "string",
            default: "",
            description: "Patient's postal code",
          },
          {
            displayName: "Sex",
            name: "sex",
            type: "string",
            default: "",
            description: "Patient's biological sex (male, female, etc.)",
          },
          {
            displayName: "Social Security Number",
            name: "socialSecurityNumber",
            type: "string",
            default: "",
            description:
              "Patient's social security number (13-15 characters, France only) - may require special permissions",
          },
          {
            displayName: "Title",
            name: "title",
            type: "string",
            default: "",
            description: "Patient's title (Mr, Mrs, Dr, etc.)",
          },
        ],
      },
      {
        displayName: "Place of Birth",
        name: "placeOfBirth",
        type: "collection",
        placeholder: "Add Place of Birth",
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Name",
            name: "name",
            type: "string",
            default: "",
            description: "Name of the place of birth",
          },
          {
            displayName: "Code",
            name: "code",
            type: "string",
            default: "",
            description:
              "The code for the place of birth (INSEE Code for France practices)",
          },
        ],
      },
      {
        displayName: "Communication Preferences",
        name: "communicationPreferences",
        type: "collection",
        placeholder: "Add Communication Preferences",
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Payment Reminders",
            name: "paymentReminders",
            type: "boolean",
            default: true,
            description:
              "Whether the patient wants to receive payment reminders",
          },
          {
            displayName: "Privacy Policy",
            name: "privacyPolicy",
            type: "string",
            default: "",
            description:
              "Patient's privacy policy response (accepted, declined, etc.)",
          },
          {
            displayName: "Promotional Marketing",
            name: "promotionalMarketing",
            type: "boolean",
            default: false,
            description:
              "Whether the patient wants to receive promotional marketing",
          },
          {
            displayName: "Receive Email",
            name: "receiveEmail",
            type: "boolean",
            default: true,
            description: "Whether the patient wants to receive emails",
          },
          {
            displayName: "Receive SMS",
            name: "receiveSMS",
            type: "boolean",
            default: true,
            description: "Whether the patient wants to receive SMS messages",
          },
        ],
      },
      {
        displayName: "Custom Attributes",
        name: "customAttributes",
        type: "fixedCollection",
        displayOptions: {
          show: {
            action: ["update"],
            resource: ["patient"],
          },
        },
        default: {},
        placeholder: "Add Custom Attribute",
        typeOptions: {
          multipleValues: true,
        },
        options: [
          {
            displayName: "Custom Attribute",
            name: "customAttribute",
            values: [
              {
                displayName: "Title",
                name: "title",
                type: "string",
                required: true,
                default: "",
                description: "The title of the custom attribute",
              },
              {
                displayName: "Text",
                name: "text",
                type: "string",
                required: true,
                default: "",
                description: "The text/description of the custom attribute",
              },
              {
                displayName: "Response",
                name: "response",
                type: "string",
                required: true,
                default: "",
                description: "The response value for the custom attribute",
              },
            ],
          },
        ],
      },
      // Search parameters for get many operations
      {
        displayName: "Options",
        name: "options",
        type: "collection",
        placeholder: "Add Option",
        displayOptions: {
          show: {
            action: ["getMany"],
            resource: ["patient"],
          },
        },
        default: {},
        options: [
          {
            displayName: "Search",
            name: "search",
            type: "string",
            default: "",
            description:
              "Search term to filter patients by name, email, or phone",
          },
          {
            displayName: "Page Size",
            name: "pageSize",
            type: "number",
            default: 50,
            description: "Number of patients to return per page",
          },
          {
            displayName: "Return All",
            name: "returnAll",
            type: "boolean",
            default: false,
            description:
              "Whether to return all results or only up to a given limit",
          },
        ],
      },
      // Booking Resource Fields
      ...BOOKING_FIELDS,
      // Booking Journey Update Fields
      JOURNEY_BOOKING_ID_FIELD,
      JOURNEY_STAGE_FIELD,
      CUSTOM_DATE_FIELD,
      JOURNEY_DATE_FIELD,
    ],
  };

  /**
   * Dynamic option loading methods
   * @type {Object}
   * @description Provides dynamic dropdown options for various actions
   */
  methods = {
    loadOptions: {
      /**
       * Loads booking types for booking creation dropdowns
       * @async
       * @method getBookingTypes
       * @param {ILoadOptionsFunctions} this - n8n load options context
       * @returns {Promise<INodePropertyOptions[]>} Array of booking type options
       */
      async getBookingTypes(
        this: ILoadOptionsFunctions,
      ): Promise<INodePropertyOptions[]> {
        const returnData: INodePropertyOptions[] = [];

        const query = `
query GetBookingTypes {
bookingTypes {
id
name
}
}
`;

        const response = await sembleApiRequest.call(this, query, {}, 3, false);
        const types = response.data.bookingTypes || [];

        for (const type of types) {
          returnData.push({
            name: type.name,
            value: type.id,
          });
        }

        return returnData;
      },
    },
  };

  /**
   * Main execution method for the Semble node
   *
   * Handles all CRUD operations across different Semble resources using an
   * action-based approach. Processes input data, validates parameters,
   * executes the appropriate resource operation, and returns structured results.
   *
   * The method supports:
   * - Resource operations: Patient, Booking, Product, Appointment management
   * - CRUD actions: create, update, delete, get, getAll
   * - Special actions: updateJourney (booking-specific)
   * - Batch processing: handles multiple input items
   * - Error handling: comprehensive error mapping and reporting
   *
   * @example
   * ```typescript
   * // Executed automatically by n8n when node runs
   * // Node parameters determine the operation:
   * // - action: "getAll"
   * // - resource: "patient"
   * // - returnAll: true
   * // - filters: { firstName: "John" }
   * ```
   *
   * @async
   * @method execute
   * @param this - n8n execution context providing access to parameters and utilities
   * @returns Promise resolving to array of execution data for output
   * @throws {NodeOperationError} When action is unsupported or parameters are invalid
   * @throws {NodeApiError} When API requests fail or authentication is invalid
   * @since 2.0.0
   * @description Handles all CRUD operations using action-based approach
   */
  async execute(this: IExecuteFunctions): Promise<INodeExecutionData[][]> {
    const items = this.getInputData();
    const returnData: IDataObject[] = [];
    const length = items.length;

    const action = this.getNodeParameter("action", 0) as string;
    const resource = this.getNodeParameter("resource", 0) as string;

    // Validate resource-specific actions
    if (action === "updateJourney" && resource !== "booking") {
      throw new NodeOperationError(
        this.getNode(),
        `The 'updateJourney' action is only available for booking resources`,
      );
    }

    for (let i = 0; i < length; i++) {
      try {
        let responseData: IDataObject | IDataObject[] | undefined;

        if (resource === "patient") {
          switch (action) {
            case "get":
              // Get single patient by ID
              const getSinglePatientId = this.getNodeParameter(
                "patientId",
                i,
              ) as string;

              if (!getSinglePatientId) {
                throw new NodeOperationError(
                  this.getNode(),
                  "Patient ID is required for get operation",
                );
              }

              const getVariables = { id: getSinglePatientId };

              try {
                // Add validation using core services
                const validationService = Semble.getValidationService();
                const eventSystem = Semble.getEventSystem();

                // Emit operation start event
                await eventSystem.emit({
                  type: "node.executed",
                  timestamp: Date.now(),
                  source: "semble-node",
                  id: `patient-get-${Date.now()}`,
                  nodeType: "semble",
                  operation: "patient.get",
                  duration: 0,
                  success: true,
                });

                const getResponse = await sembleApiRequest.call(
                  this,
                  GET_PATIENT_QUERY,
                  getVariables,
                  3,
                  false,
                );

                if (!getResponse.patient) {
                  throw new NodeApiError(this.getNode(), {
                    message: `Patient with ID ${getSinglePatientId} not found`,
                    description: "The specified patient ID does not exist",
                  });
                }

                responseData = getResponse.patient;
              } catch (error) {
                if (error instanceof NodeApiError) {
                  throw error;
                }

                throw new NodeApiError(this.getNode(), {
                  message: `Failed to get patient: ${(error as Error).message}`,
                  description: (error as Error).message,
                });
              }
              break;

            case "getMany":
              // Get multiple patients using modular pagination
              const options = this.getNodeParameter(
                "options",
                i,
              ) as IDataObject;
              const paginationConfig = buildPaginationConfig(options);

              try {
                const paginationResult = await SemblePagination.execute(this, {
                  query: GET_PATIENTS_QUERY,
                  baseVariables: {},
                  dataPath: "patients",
                  pageSize: paginationConfig.pageSize,
                  returnAll: paginationConfig.returnAll,
                  search: paginationConfig.search,
                  options: {},
                });

                responseData = paginationResult.data;
              } catch (error) {
                throw new NodeApiError(this.getNode(), {
                  message: `Failed to get patients: ${(error as Error).message}`,
                  description: (error as Error).message,
                });
              }
              break;
            case "create":
              // Create new patient using shared mutation
              const firstName = this.getNodeParameter("firstName", i) as string;
              const lastName = this.getNodeParameter("lastName", i) as string;
              const additionalFields = this.getNodeParameter(
                "additionalFields",
                i,
              ) as IDataObject;
              const placeOfBirth = this.getNodeParameter(
                "placeOfBirth",
                i,
              ) as IDataObject;
              const communicationPreferences = this.getNodeParameter(
                "communicationPreferences",
                i,
              ) as IDataObject;
              const customAttributesData = this.getNodeParameter(
                "customAttributes",
                i,
              ) as IDataObject;

              if (!firstName || !lastName) {
                throw new NodeOperationError(
                  this.getNode(),
                  "First Name and Last Name are required for create operation",
                );
              }

              // Build patient data object from the API introspection
              const patientData: IDataObject = {
                first: firstName,
                last: lastName,
                ...additionalFields,
              };

              // Add placeOfBirth if provided
              if (placeOfBirth && (placeOfBirth.name || placeOfBirth.code)) {
                patientData.placeOfBirth = placeOfBirth;
              }

              // Add communicationPreferences if provided
              if (
                communicationPreferences &&
                Object.keys(communicationPreferences).length > 0
              ) {
                patientData.communicationPreferences = communicationPreferences;
              }

              // Add customAttributes if provided
              if (
                customAttributesData &&
                customAttributesData.customAttribute
              ) {
                const customAttributes = (
                  customAttributesData.customAttribute as IDataObject[]
                ).map((attr) => ({
                  title: attr.title,
                  text: attr.text,
                  response: attr.response,
                }));
                patientData.customAttributes = customAttributes;
              }

              const createVariables = {
                patientData,
                insData: null, // Insurance data as string (JSON stringified object)
              };

              try {
                const createResponse = await sembleApiRequest.call(
                  this,
                  CREATE_PATIENT_MUTATION,
                  createVariables,
                  3,
                  false,
                );
                const createResult = createResponse.createPatient;

                if (createResult.error) {
                  throw new NodeApiError(this.getNode(), {
                    message: `Failed to create patient: ${createResult.error}`,
                    description: createResult.error,
                  });
                }

                responseData = createResult.data;
              } catch (error) {
                if (error instanceof NodeApiError) {
                  throw error;
                }

                throw new NodeApiError(this.getNode(), {
                  message: `Failed to create patient: ${(error as Error).message}`,
                  description: (error as Error).message,
                });
              }
              break;
            case "update":
              // Update patient using shared mutation
              const updatePatientId = this.getNodeParameter(
                "patientId",
                i,
              ) as string;
              const updateFields = this.getNodeParameter(
                "updateFields",
                i,
              ) as IDataObject;
              const updatePlaceOfBirth = this.getNodeParameter(
                "placeOfBirth",
                i,
              ) as IDataObject;
              const updateCommunicationPreferences = this.getNodeParameter(
                "communicationPreferences",
                i,
              ) as IDataObject;
              const updateCustomAttributesData = this.getNodeParameter(
                "customAttributes",
                i,
              ) as IDataObject;

              if (!updatePatientId) {
                throw new NodeOperationError(
                  this.getNode(),
                  "Patient ID is required for update operation",
                );
              }

              // Build patient data object from updateFields
              const updatePatientData: IDataObject = {
                ...updateFields,
              };

              // Map first name and last name to the API fields
              if (updateFields.firstName) {
                updatePatientData.first = updateFields.firstName;
                delete updatePatientData.firstName;
              }
              if (updateFields.lastName) {
                updatePatientData.last = updateFields.lastName;
                delete updatePatientData.lastName;
              }

              // Add placeOfBirth if provided
              if (
                updatePlaceOfBirth &&
                (updatePlaceOfBirth.name || updatePlaceOfBirth.code)
              ) {
                updatePatientData.placeOfBirth = updatePlaceOfBirth;
              }

              // Add communicationPreferences if provided
              if (
                updateCommunicationPreferences &&
                Object.keys(updateCommunicationPreferences).length > 0
              ) {
                updatePatientData.communicationPreferences =
                  updateCommunicationPreferences;
              }

              // Add customAttributes if provided
              if (
                updateCustomAttributesData &&
                updateCustomAttributesData.customAttribute
              ) {
                const customAttributes = (
                  updateCustomAttributesData.customAttribute as IDataObject[]
                ).map((attr) => ({
                  title: attr.title,
                  text: attr.text,
                  response: attr.response,
                }));
                updatePatientData.customAttributes = customAttributes;
              }

              const updateVariables = {
                id: updatePatientId,
                patientData: updatePatientData,
              };

              try {
                const updateResponse = await sembleApiRequest.call(
                  this,
                  UPDATE_PATIENT_MUTATION,
                  updateVariables,
                  3,
                  false,
                );
                const updateResult = updateResponse.updatePatient;

                if (updateResult.error) {
                  throw new NodeApiError(this.getNode(), {
                    message: `Failed to update patient: ${updateResult.error}`,
                    description: updateResult.error,
                  });
                }

                responseData = updateResult.data;
              } catch (error) {
                if (error instanceof NodeApiError) {
                  throw error;
                }

                throw new NodeApiError(this.getNode(), {
                  message: `Failed to update patient: ${(error as Error).message}`,
                  description: (error as Error).message,
                });
              }
              break;
            case "delete":
              // Delete patient using shared mutation
              const patientId = this.getNodeParameter("patientId", i) as string;

              if (!patientId) {
                throw new NodeOperationError(
                  this.getNode(),
                  "Patient ID is required for delete operation",
                );
              }

              const deleteVariables = { id: patientId };

              try {
                const deleteResponse = await sembleApiRequest.call(
                  this,
                  DELETE_PATIENT_MUTATION,
                  deleteVariables,
                  3,
                  false,
                );
                const deleteResult = deleteResponse.deletePatient;

                if (deleteResult.error) {
                  throw new NodeApiError(this.getNode(), {
                    message: `Failed to delete patient: ${deleteResult.error}`,
                    description: deleteResult.error,
                  });
                }

                responseData = {
                  success: true,
                  patientId,
                  deletedPatient: deleteResult.data,
                  message: `Patient ${deleteResult.data?.firstName} ${deleteResult.data?.lastName} (${patientId}) deleted successfully`,
                };
              } catch (error) {
                if (error instanceof NodeApiError) {
                  throw error;
                }

                throw new NodeApiError(this.getNode(), {
                  message: `Failed to delete patient: ${(error as Error).message}`,
                  description: (error as Error).message,
                });
              }
              break;
            default:
              throw new NodeOperationError(
                this.getNode(),
                `Unknown patient action: ${action}`,
              );
          }
        } else if (resource === "product") {
          // Handle product resource using ProductResource action hooks
          responseData = await ProductResource.executeAction(this, action, i);
        } else if (resource === "booking") {
          // Handle booking resource using BookingResource action hooks
          responseData = await BookingResource.executeAction(this, action, i);
        } else {
          // Handle other resources with placeholder responses
          const resourceName = this.getNodeParameter("resource", i) as string;

          switch (action) {
            case "get":
              responseData = {
                message: "Get action not yet implemented",
              };
              break;
            case "create":
              responseData = {
                message: "Create action not yet implemented",
              };
              break;
            case "update":
              responseData = {
                message: "Update action not yet implemented",
              };
              break;
            case "delete":
              responseData = {
                message: "Delete action not yet implemented",
              };
              break;
            default:
              responseData = {
                message: `Unknown action: ${action}`,
              };
              break;
          }
        }

        if (Array.isArray(responseData)) {
          returnData.push(...(responseData as IDataObject[]));
        } else if (responseData !== undefined) {
          returnData.push(responseData as IDataObject);
        }
      } catch (error) {
        if (this.continueOnFail()) {
          returnData.push({ error: (error as Error).message });
          continue;
        }
        throw error;
      }
    }

    return [this.helpers.returnJsonArray(returnData)];
  }
}
