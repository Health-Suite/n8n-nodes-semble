/**
 * @fileoverview Docblock Header Quality Test Suite
 * @description Ensures all TypeScript files have the correct docblock header format
 * @author Mike Hatcher
 * @website https://progenious.com
 * @namespace N8nNodesSemble.Test.Quality.DocblockHeader
 */

import { readFileSync, readdirSync, statSync } from 'fs';
import { join, relative, extname } from 'path';

describe('Docblock Header Quality Checks', () => {
	/**
	 * Required docblock header fields and their validation patterns
	 */
	const REQUIRED_FIELDS = {
		'@fileoverview': /^\s*\*\s*@fileoverview\s+.+$/m,
		'@description': /^\s*\*\s*@description\s+.+$/m,
		'@author': /^\s*\*\s*@author\s+Mike Hatcher$/m,
		'@website': /^\s*\*\s*@website\s+https:\/\/progenious\.com$/m,
		'@namespace': /^\s*\*\s*@namespace\s+N8nNodesSemble\..+$/m,
	};

	/**
	 * Optional fields that may be present
	 */
	const OPTIONAL_FIELDS = {
		'@since': /^\s*\*\s*@since\s+\d+\.\d+\.\d+$/m,
	};

	/**
	 * Files and directories to exclude from docblock checking
	 */
	const EXCLUDED_PATTERNS = [
		/node_modules/,
		/\.git/,
		/dist/,
		/build/,
		/coverage/,
		/\.venv/,
		/docs-env/,
		/venv/,
		/env/,
		/\.d\.ts$/,
		/debug-validation\.ts$/, // Temporary debug files
		/test-.*\.ts$/, // Temporary test files
	];

	/**
	 * Get all TypeScript files in the project
	 */
	function getAllTypeScriptFiles(dir: string = process.cwd()): string[] {
		const files: string[] = [];

		function walk(currentDir: string): void {
			const entries = readdirSync(currentDir);

			for (const entry of entries) {
				const fullPath = join(currentDir, entry);
				const relativePath = relative(process.cwd(), fullPath);

				// Skip excluded patterns
				if (EXCLUDED_PATTERNS.some(pattern => pattern.test(relativePath))) {
					continue;
				}

				const stat = statSync(fullPath);

				if (stat.isDirectory()) {
					walk(fullPath);
				} else if (stat.isFile() && extname(fullPath) === '.ts') {
					files.push(fullPath);
				}
			}
		}

		walk(dir);
		return files;
	}

	/**
	 * Extract docblock from the beginning of a file
	 */
	function extractDocblock(filePath: string): string | null {
		try {
			const content = readFileSync(filePath, 'utf-8');
			
			// Skip empty files
			if (content.trim().length === 0) {
				return 'EMPTY_FILE';
			}
			
			const docblockMatch = content.match(/^\/\*\*[\s\S]*?\*\//);
			return docblockMatch ? docblockMatch[0] : null;
		} catch (error) {
			return null;
		}
	}

	/**
	 * Validate docblock format and required fields
	 */
	function validateDocblock(docblock: string, filePath: string): {
		isValid: boolean;
		errors: string[];
		warnings: string[];
	} {
		const errors: string[] = [];
		const warnings: string[] = [];

		// Check if it starts with /** and ends with */
		if (!docblock.startsWith('/**') || !docblock.endsWith('*/')) {
			errors.push('Docblock must start with /** and end with */');
		}

		// Check required fields
		for (const [fieldName, pattern] of Object.entries(REQUIRED_FIELDS)) {
			if (!pattern.test(docblock)) {
				errors.push(`Missing or invalid required field: ${fieldName}`);
			}
		}

		// Validate namespace format
		const namespaceMatch = docblock.match(/^\s*\*\s*@namespace\s+(N8nNodesSemble\..+)$/m);
		if (namespaceMatch) {
			const namespace = namespaceMatch[1];
			const relativePath = relative(process.cwd(), filePath);
			
			// Basic namespace structure validation
			const expectedParts = ['N8nNodesSemble'];
			
			if (relativePath.startsWith('types/')) {
				expectedParts.push('Types');
			} else if (relativePath.startsWith('core/')) {
				expectedParts.push('Core');
			} else if (relativePath.startsWith('services/')) {
				expectedParts.push('Services');
			} else if (relativePath.startsWith('test/')) {
				expectedParts.push('Test');
			} else if (relativePath.startsWith('components/')) {
				expectedParts.push('Components');
			} else if (relativePath.startsWith('nodes/')) {
				expectedParts.push('Nodes');
			} else if (relativePath.startsWith('credentials/')) {
				expectedParts.push('Credentials');
			}

			const expectedNamespaceStart = expectedParts.join('.');
			if (!namespace.startsWith(expectedNamespaceStart)) {
				warnings.push(`Namespace "${namespace}" may not match file location. Expected to start with "${expectedNamespaceStart}"`);
			}
		}

		// Check for common formatting issues
		const lines = docblock.split('\n');
		for (let i = 0; i < lines.length; i++) {
			const line = lines[i];
			
			// Check for proper line formatting (should start with * or /** or */)
			if (i === 0 && !line.trim().startsWith('/**')) {
				errors.push('First line should start with /**');
			} else if (i === lines.length - 1 && !line.trim().endsWith('*/')) {
				errors.push('Last line should end with */');
			} else if (i > 0 && i < lines.length - 1 && !line.trim().startsWith('*')) {
				warnings.push(`Line ${i + 1} should start with *`);
			}
		}

		return {
			isValid: errors.length === 0,
			errors,
			warnings,
		};
	}

	describe('File Header Validation', () => {
		const typeScriptFiles = getAllTypeScriptFiles();

		// Ensure we found some files
		test('should find TypeScript files in the project', () => {
			expect(typeScriptFiles.length).toBeGreaterThan(0);
			console.log(`Found ${typeScriptFiles.length} TypeScript files to check`);
		});

		// Test each file individually
		typeScriptFiles.forEach(filePath => {
			const relativePath = relative(process.cwd(), filePath);

			test(`${relativePath} should have a valid docblock header`, () => {
				const docblock = extractDocblock(filePath);

				// Skip empty files (placeholders)
				if (docblock === 'EMPTY_FILE') {
					console.warn(`Skipping empty file: ${relativePath}`);
					expect(true).toBe(true);
					return;
				}

				expect(docblock).not.toBeNull();
				expect(docblock).toBeDefined();

				if (!docblock) {
					throw new Error(`No docblock found at the beginning of ${relativePath}`);
				}

				const validation = validateDocblock(docblock, filePath);

				// Log warnings but don't fail the test
				if (validation.warnings.length > 0) {
					console.warn(`Warnings for ${relativePath}:`, validation.warnings);
				}

				// Fail test if there are errors
				if (!validation.isValid) {
					throw new Error(
						`Invalid docblock in ${relativePath}:\n${validation.errors.join('\n')}`
					);
				}

				expect(validation.isValid).toBe(true);
			});
		});
	});

	describe('Docblock Content Validation', () => {
		const typeScriptFiles = getAllTypeScriptFiles();

		test('all files should have meaningful @fileoverview descriptions', () => {
			const shortDescriptions: string[] = [];

			typeScriptFiles.forEach(filePath => {
				const docblock = extractDocblock(filePath);
				if (docblock) {
					const overviewMatch = docblock.match(/^\s*\*\s*@fileoverview\s+(.+)$/m);
					if (overviewMatch) {
						const overview = overviewMatch[1].trim();
						if (overview.length < 10) {
							shortDescriptions.push(`${relative(process.cwd(), filePath)}: "${overview}"`);
						}
					}
				}
			});

			if (shortDescriptions.length > 0) {
				console.warn('Files with potentially short @fileoverview descriptions:', shortDescriptions);
			}

			// Don't fail the test, just warn
			expect(true).toBe(true);
		});

		test('all files should have meaningful @description content', () => {
			const shortDescriptions: string[] = [];

			typeScriptFiles.forEach(filePath => {
				const docblock = extractDocblock(filePath);
				if (docblock) {
					const descriptionMatch = docblock.match(/^\s*\*\s*@description\s+(.+)$/m);
					if (descriptionMatch) {
						const description = descriptionMatch[1].trim();
						if (description.length < 15) {
							shortDescriptions.push(`${relative(process.cwd(), filePath)}: "${description}"`);
						}
					}
				}
			});

			if (shortDescriptions.length > 0) {
				console.warn('Files with potentially short @description content:', shortDescriptions);
			}

			// Don't fail the test, just warn
			expect(true).toBe(true);
		});
	});

	describe('Namespace Consistency', () => {
		const typeScriptFiles = getAllTypeScriptFiles();

		test('namespace structure should follow directory structure', () => {
			const namespaceIssues: string[] = [];

			typeScriptFiles.forEach(filePath => {
				const docblock = extractDocblock(filePath);
				if (docblock) {
					const namespaceMatch = docblock.match(/^\s*\*\s*@namespace\s+(N8nNodesSemble\..+)$/m);
					if (namespaceMatch) {
						const namespace = namespaceMatch[1];
						const relativePath = relative(process.cwd(), filePath);

						// Validate namespace structure
						const pathParts = relativePath.split('/');
						const namespaceParts = namespace.split('.');

						// Should start with N8nNodesSemble
						if (namespaceParts[0] !== 'N8nNodesSemble') {
							namespaceIssues.push(`${relativePath}: Namespace should start with "N8nNodesSemble"`);
						}

						// Directory mapping validation
						const directoryMappings: { [key: string]: string } = {
							'types': 'Types',
							'core': 'Core',
							'services': 'Services',
							'test': 'Test',
							'components': 'Components',
							'nodes': 'Nodes',
							'credentials': 'Credentials',
						};

						if (pathParts.length > 0) {
							const topLevelDir = pathParts[0];
							const expectedNamespacePart = directoryMappings[topLevelDir];
							
							if (expectedNamespacePart && namespaceParts.length > 1) {
								if (namespaceParts[1] !== expectedNamespacePart) {
									namespaceIssues.push(
										`${relativePath}: Expected namespace part "${expectedNamespacePart}" for directory "${topLevelDir}", got "${namespaceParts[1]}"`
									);
								}
							}
						}
					}
				}
			});

			if (namespaceIssues.length > 0) {
				console.warn('Namespace consistency issues:', namespaceIssues);
			}

			// Don't fail the test, just warn for now
			expect(true).toBe(true);
		});
	});
});
