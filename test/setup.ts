/**
 * @fileoverview Global test setup for n8n-nodes-semble
 * @description Configures Jest environment and global mocks following n8n best practices
 * @author Mike Hatcher
 * @website https://progenious.com
 * @namespace N8nNodesSemble.Tests.Setup
 * @since 2.0.0
 */

/**
 * Global test timeout configuration
 * Increased for API operations that may take time
 */
jest.setTimeout(30000);

/**
 * Mock console methods to reduce noise in test output
 * Uncomment if you want to suppress console output during tests
 */
// global.console = {
//   ...console,
//   // Keep error and warn for debugging
//   log: jest.fn(),
//   debug: jest.fn(),
//   info: jest.fn(),
// };

/**
 * Global test environment variables
 * These will be available in all tests
 */
process.env.NODE_ENV = 'test';
process.env.TZ = 'UTC'; // Ensure consistent timezone for date tests

/**
 * Global error handler for unhandled promise rejections
 * Helps catch async errors that might otherwise be silent
 */
process.on('unhandledRejection', (reason, promise) => {
  console.error('Unhandled Rejection at:', promise, 'reason:', reason);
  // Don't exit the process in tests, just log the error
});

/**
 * Global cleanup after all tests
 */
afterAll(async () => {
  // Add any global cleanup logic here
  jest.clearAllMocks();
  jest.restoreAllMocks();
  
  // Clean up singleton services that might have open handles
  try {
    const { serviceContainer } = await import('../core/ServiceContainer');
    const { eventSystem } = await import('../core/EventSystem');
    
    // Clear all registered services and listeners
    serviceContainer.clear();
    eventSystem.clear();
    
    // Give a moment for cleanup to complete
    await new Promise(resolve => {
      const t = setTimeout(resolve, 100);
      t.unref();
    });
  } catch (error) {
    // Ignore errors during cleanup - services may not be initialized
    console.debug('Cleanup warning (can be ignored):', error instanceof Error ? error.message : String(error));
  }
});
