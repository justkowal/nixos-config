import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to upload an attachment (photo) to the Messenger Platform API.
 *
 * @param {Object} args - Arguments for the attachment upload.
 * @param {string} args.pageId - The ID of the Facebook page where the attachment will be uploaded.
 * @param {string} args.version - The version of the Messenger API to use.
 * @param {string} args.url - The URL of the image to upload.
 * @param {boolean} args.isReusable - Indicates if the attachment is reusable.
 * @returns {Promise<Object>} - The result of the attachment upload.
 */
const executeFunction = async (args = {}) => {
  const { pageId, version, url, isReusable } = args;
  const baseUrl = 'https://graph.facebook.com';
  const token = getToken();

  try {
    // Construct the URL for the attachment upload
    const endpoint = `${baseUrl}/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/message_attachments`;

    // Prepare the request body
    const body = {
      message: {
        attachment: {
          type: 'image',
          payload: {
            url: url,
            is_reusable: isReusable
          }
        }
      }
    };

    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json'
    };

    // If a token is provided, add it to the Authorization header
    if (token) {
      headers['Authorization'] = `Bearer ${token}`;
    }

    // Perform the fetch request
    const response = await fetch(endpoint, {
      method: 'POST',
      headers,
      body: JSON.stringify(body)
    });

    // Check if the response was successful
    if (!response.ok) {
      const errorData = await response.json();
      throw new Error(JSON.stringify(errorData));
    }

    // Parse and return the response data
    const data = await response.json();
    return data;
  } catch (error) {
    console.error('Error uploading attachment:', error);
    return {
      error: `An error occurred while uploading the attachment: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for uploading an attachment to the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'upload_attachment',
      description: 'Upload an attachment (photo) to the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageId: {
            type: 'string',
            description: 'The ID of the Facebook page where the attachment will be uploaded.'
          },
          version: {
            type: 'string',
            description: 'The version of the Messenger API to use.'
          },
          url: {
            type: 'string',
            description: 'The URL of the image to upload.'
          },
          isReusable: {
            type: 'boolean',
            description: 'Indicates if the attachment is reusable.'
          }
        },
        required: ['pageId', 'version', 'url', 'isReusable']
      }
    }
  }
};

export { apiTool };