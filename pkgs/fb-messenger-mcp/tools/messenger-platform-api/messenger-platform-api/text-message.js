import { getToken, getPageId } from "../../../lib/fb.js";

/**
 * Function to send a text message using the Messenger Platform API.
 *
 * @param {Object} args - Arguments for sending the message.
 * @param {string} args.pageScopedId - The Page-scoped ID (PSID) of the recipient.
 * @param {string} args.messageText - The text of the message to be sent.
 * @returns {Promise<Object>} - The result of the message sending operation.
 */
const executeFunction = async (args = {}) => {
  const { pageScopedId, messageText } = args;
  const version = 'v20.0'; // Facebook API version
  const pageId = getPageId(args.pageId);
  const token = getToken();
  const url = `https://graph.facebook.com/${version}/${getPageId(typeof pageId !== "undefined" ? pageId : args.pageId)}/messages`;
  
  const body = {
    recipient: {
      id: pageScopedId
    },
    message: {
      text: messageText
    }
  };

  try {
    // Set up headers for the request
    const headers = {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${token}`
    };

    // Perform the fetch request
    const response = await fetch(url, {
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
    console.error('Error sending message:', error);
    return {
      error: `An error occurred while sending the message: ${error instanceof Error ? error.message : JSON.stringify(error)}`
    };
  }
};

/**
 * Tool configuration for sending text messages using the Messenger Platform API.
 * @type {Object}
 */
const apiTool = {
  function: executeFunction,
  definition: {
    type: 'function',
    function: {
      name: 'send_text_message',
      description: 'Send a text message to a recipient using the Messenger Platform API.',
      parameters: {
        type: 'object',
        properties: {
          pageScopedId: {
            type: 'string',
            description: 'The Page-scoped ID (PSID) of the recipient.'
          },
          messageText: {
            type: 'string',
            description: 'The text of the message to be sent.'
          }
        },
        required: ['pageScopedId', 'messageText']
      }
    }
  }
};

export { apiTool };